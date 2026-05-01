import Foundation

public protocol PlaybackCoordinator: Sendable {
    var nowPlaying: NowPlaying? { get async }
    var nowPlayingUpdates: AsyncStream<NowPlaying> { get async }

    func play(channelId: Int) async throws
    func pause() async throws
    func resume() async throws
    func stop() async throws
    func skipForward() async throws
    func changeChannel(to channelId: Int) async throws
    func shutdown() async
}

public actor LivePlaybackCoordinator: PlaybackCoordinator {
    private let api: any RpApiClient
    private let engine: any PlayerEngine
    private let logger: any Logging
    private let bitrateProvider: @Sendable () async -> Int

    private var currentChannelId: Int?
    private var currentBlock: GetBlock?
    private var orderedSongs: [PlayListSong] = []
    private var startsAt: [Double] = []
    private var currentSongIndex: Int = 0
    private var currentPositionSeconds: Double = 0
    private var current: NowPlaying?
    private var continuations: [UUID: AsyncStream<NowPlaying>.Continuation] = [:]
    private var eventTask: Task<Void, Never>?
    private var prefetchedBlock: GetBlock?
    private var prefetchTask: Task<Void, Never>?
    private var channelCursors: [Int: Int] = [:]
    private var isShutdown = false

    public init(
        api: any RpApiClient,
        engine: any PlayerEngine,
        logger: any Logging,
        bitrateProvider: @escaping @Sendable () async -> Int
    ) {
        self.api = api
        self.engine = engine
        self.logger = logger
        self.bitrateProvider = bitrateProvider
    }

    public var nowPlaying: NowPlaying? { current }

    public var nowPlayingUpdates: AsyncStream<NowPlaying> {
        let id = UUID()
        return AsyncStream { continuation in
            if self.isShutdown { continuation.finish(); return }
            self.continuations[id] = continuation
            if let current = self.current { continuation.yield(current) }
            continuation.onTermination = { [weak self] _ in
                Task { [weak self] in await self?.unregister(id: id) }
            }
        }
    }

    public func play(channelId: Int) async throws {
        logger.debug("play(channelId: \(channelId))")
        await ensureEventSubscription()
        let bitrate = await bitrateProvider()
        let cursor = channelCursors[channelId]
        logger.debug("play resolved bitrate=\(bitrate) cursor=\(cursor.map(String.init) ?? "nil")")
        let block = try await api.getBlock(channel: channelId, bitrate: bitrate, info: true, event: cursor)
        let songs = BlockSongs.orderedSongs(from: block)
        guard !songs.isEmpty else { throw PlaybackCoordinatorError.blockHasNoSongs }

        let starts = BlockSongs.startsAtSeconds(songs: songs)
        logger.debug("play block (expiration=\(block.expiration)):\n\(describeBlock(url: block.url, songs: songs, starts: starts))")

        let startPos = block.cue > 0 ? Double(block.cue) / 1000.0 : 0
        currentChannelId = channelId
        currentBlock = block
        orderedSongs = songs
        startsAt = starts
        currentSongIndex = 0
        currentPositionSeconds = startPos

        let startSeconds: Double? = startPos > 0 ? startPos : nil
        guard let url = URL(string: block.url) else {
            throw PlaybackCoordinatorError.engineError(message: "invalid block url: \(block.url)")
        }
        logger.debug("play engine.play url=\(url.absoluteString) startSeconds=\(startSeconds.map { "\($0)s" } ?? "nil (beginning)")")
        do {
            try await engine.play(url: url, startSeconds: startSeconds)
        } catch {
            throw PlaybackCoordinatorError.engineError(message: String(describing: error))
        }
        emitNowPlaying(forSongIndex: 0)
    }

    public func pause() async throws {
        logger.debug("pause()")
        guard currentBlock != nil else { throw PlaybackCoordinatorError.notPlaying }
        do { try await engine.pause() } catch { throw PlaybackCoordinatorError.engineError(message: String(describing: error)) }
    }

    public func resume() async throws {
        logger.debug("resume()")
        guard let block = currentBlock else { throw PlaybackCoordinatorError.notPlaying }
        if block.expiration > 0,
           Date().timeIntervalSince1970 > Double(block.expiration),
           let channelId = currentChannelId {
            logger.info("resume: block expired (now=\(Int(Date().timeIntervalSince1970)) > expiration=\(block.expiration)), refetching")
            try await play(channelId: channelId)
            return
        }
        logger.debug("resume: block fresh, engine.resume()")
        do { try await engine.resume() } catch { throw PlaybackCoordinatorError.engineError(message: String(describing: error)) }
    }

    public func stop() async throws {
        logger.debug("stop()")
        // Clear coordinator state BEFORE awaiting engine.stop. If we cleared
        // afterwards, a queued positionUpdate event processed during the
        // engine.stop suspension would see the still-active orderedSongs and
        // could spawn a fresh prefetch task that survives the cleanup.
        prefetchTask?.cancel()
        prefetchTask = nil
        prefetchedBlock = nil
        currentBlock = nil
        orderedSongs = []
        startsAt = []
        currentSongIndex = 0
        currentPositionSeconds = 0
        current = nil
        do { try await engine.stop() } catch { throw PlaybackCoordinatorError.engineError(message: String(describing: error)) }
    }

    public func skipForward() async throws {
        logger.debug("skipForward at songIndex=\(currentSongIndex), pos=\(currentPositionSeconds)")
        guard currentBlock != nil, !orderedSongs.isEmpty,
              let channelId = currentChannelId else {
            throw PlaybackCoordinatorError.notPlaying
        }
        let nextIndex = currentSongIndex + 1
        if nextIndex < orderedSongs.count {
            // Seek slightly past the boundary so positionUpdate trips into the new song.
            let target = startsAt[nextIndex] + 0.05
            let nextSong = orderedSongs[nextIndex]
            logger.debug("skipForward in-block: url=\(currentBlock?.url ?? "?") seek to \(target)s → song [\(nextIndex)] '\(nextSong.artist) – \(nextSong.title)'")
            if let chan = currentChannelId,
               let skippedEvent = Int(orderedSongs[currentSongIndex].event ?? "") {
                channelCursors[chan] = skippedEvent
                logger.debug("cursor[\(chan)] = \(skippedEvent) (skipForward in-block)")
            }
            do {
                try await engine.seek(to: target)
            } catch {
                throw PlaybackCoordinatorError.engineError(message: String(describing: error))
            }
            currentSongIndex = nextIndex
            currentPositionSeconds = target
            emitNowPlaying(forSongIndex: nextIndex)
        } else {
            let endEvent: Int? = Int(currentBlock?.endEvent ?? "")
            if let endEvent, let chan = currentChannelId {
                channelCursors[chan] = endEvent
                logger.debug("cursor[\(chan)] = \(endEvent) (skipForward past-last)")
            }
            if prefetchedBlock != nil {
                logger.debug("skipForward past-last: adopting prefetched block")
                await swapToPrefetchedBlockIfAvailable()
                return
            }
            if prefetchTask != nil {
                logger.debug("skipForward past-last: cancelling in-flight prefetch")
                prefetchTask?.cancel()
                prefetchTask = nil
            }
            let bitrate = await bitrateProvider()
            logger.debug("skipForward past last song, fetching next block channel=\(channelId) bitrate=\(bitrate) event=\(endEvent.map(String.init) ?? "nil")")
            let block = try await api.getBlock(channel: channelId, bitrate: bitrate, info: true, event: endEvent)
            let songs = BlockSongs.orderedSongs(from: block)
            guard !songs.isEmpty else { throw PlaybackCoordinatorError.blockHasNoSongs }
            let newStarts = BlockSongs.startsAtSeconds(songs: songs)
            logger.debug("skipForward next block:\n\(describeBlock(url: block.url, songs: songs, starts: newStarts))")
            currentBlock = block
            orderedSongs = songs
            startsAt = newStarts
            currentSongIndex = 0
            let startPos = block.cue > 0 ? Double(block.cue) / 1000.0 : 0
            currentPositionSeconds = startPos
            guard let url = URL(string: block.url) else {
                throw PlaybackCoordinatorError.engineError(message: "invalid block url: \(block.url)")
            }
            let startSeconds: Double? = startPos > 0 ? startPos : nil
            logger.debug("skipForward engine.play url=\(url.absoluteString) startSeconds=\(startSeconds.map { "\($0)s" } ?? "nil")")
            do {
                try await engine.play(url: url, startSeconds: startSeconds)
            } catch {
                throw PlaybackCoordinatorError.engineError(message: String(describing: error))
            }
            emitNowPlaying(forSongIndex: 0)
        }
    }

    public func changeChannel(to channelId: Int) async throws {
        prefetchTask?.cancel()
        prefetchTask = nil
        prefetchedBlock = nil
        try await stop()
        try await play(channelId: channelId)
    }

    public func shutdown() async {
        guard !isShutdown else { return }
        isShutdown = true
        eventTask?.cancel()
        await eventTask?.value
        eventTask = nil
        try? await engine.stop()
        for c in continuations.values { c.finish() }
        continuations.removeAll()
    }

    // Idempotent. Awaited from inside actor isolation, so by the time it returns
    // the engine.events stream has been subscribed. Deterministic vs the previous
    // init-time Task bootstrap, which raced with the first command.
    private func ensureEventSubscription() async {
        guard eventTask == nil else { return }
        let stream = await engine.events
        eventTask = Task { [weak self] in
            for await event in stream {
                guard let self else { return }
                await self.handleEngineEvent(event)
            }
        }
    }

    private func handleEngineEvent(_ event: PlayerEvent) async {
        switch event {
        case .fileLoaded:
            logger.debug("engine fileLoaded")
        case .positionUpdate(let seconds):
            currentPositionSeconds = seconds
            guard !startsAt.isEmpty else { return }
            let newIndex = BlockSongs.indexOfSong(at: seconds, in: startsAt)
            if newIndex != currentSongIndex {
                logger.debug("song boundary crossed: \(currentSongIndex) -> \(newIndex) at pos=\(seconds)")
                if let chan = currentChannelId,
                   currentSongIndex < orderedSongs.count,
                   let finishedEvent = Int(orderedSongs[currentSongIndex].event ?? "") {
                    channelCursors[chan] = finishedEvent
                    logger.debug("cursor[\(chan)] = \(finishedEvent) (auto-advance)")
                }
                currentSongIndex = newIndex
                emitNowPlaying(forSongIndex: newIndex)
            }
            maybeStartPrefetch()
        case .fileEnded(let reason):
            logger.debug("engine fileEnded: \(reason)")
            if case .eof = reason {
                await swapToPrefetchedBlockIfAvailable()
            }
        case .error(let message):
            logger.error("player engine reported error: \(message)")
        case .outputDeviceChanged, .shutdown:
            break
        }
    }

    private func emitNowPlaying(forSongIndex idx: Int) {
        guard let channelId = currentChannelId, idx < orderedSongs.count else { return }
        let song = orderedSongs[idx]
        let songStart = startsAt[idx]
        let songEnd = songStart + Double(song.duration) / 1000.0
        let np = NowPlaying(
            channelId: channelId,
            song: song,
            songIndexInBlock: idx,
            blockDurationSeconds: BlockSongs.totalDurationSeconds(songs: orderedSongs),
            songStartSeconds: songStart,
            songEndSeconds: songEnd,
            blockBitrate: currentBlock?.bitrate
        )
        current = np
        for c in continuations.values { c.yield(np) }
    }

    private func describeBlock(url: String, songs: [PlayListSong], starts: [Double]) -> String {
        let lines = songs.enumerated().map { i, song in
            String(format: "  [%d] %7.1fs  %@ – %@ (%.1fs)", i, starts[i], song.artist, song.title, Double(song.duration) / 1000.0)
        }
        return "url=\(url)\n" + lines.joined(separator: "\n")
    }

    private func unregister(id: UUID) { continuations.removeValue(forKey: id) }

    private func maybeStartPrefetch() {
        guard let channelId = currentChannelId,
              !orderedSongs.isEmpty,
              currentSongIndex == orderedSongs.count - 1,
              prefetchedBlock == nil,
              prefetchTask == nil else { return }
        let totalSeconds = BlockSongs.totalDurationSeconds(songs: orderedSongs)
        let remaining = totalSeconds - currentPositionSeconds
        guard remaining < 10.0 else { return }

        let endEvent: Int? = Int(currentBlock?.endEvent ?? "")
        if endEvent == nil {
            logger.error("prefetch: endEvent missing or non-numeric — falling back to event=nil")
        }
        let api = self.api
        let provider = self.bitrateProvider
        logger.debug("prefetch start, channel=\(channelId) event=\(endEvent.map(String.init) ?? "nil")")
        prefetchTask = Task { [weak self] in
            let bitrate = await provider()
            let result = try? await api.getBlock(channel: channelId, bitrate: bitrate, info: true, event: endEvent)
            await self?.absorbPrefetchResult(result)
        }
    }

    private func absorbPrefetchResult(_ block: GetBlock?) {
        // If cleanup (stop / changeChannel) ran during the fetch, prefetchTask
        // was nilled — discard the late result so we don't resurrect a stale block.
        guard prefetchTask != nil else { return }
        prefetchTask = nil
        if let block = block, BlockSongs.orderedSongs(from: block).isEmpty == false {
            prefetchedBlock = block
            logger.debug("prefetch absorbed: url=\(block.url)")
        }
    }

    private func swapToPrefetchedBlockIfAvailable() async {
        guard let block = prefetchedBlock else {
            currentBlock = nil
            orderedSongs = []
            startsAt = []
            currentSongIndex = 0
            currentPositionSeconds = 0
            current = nil
            return
        }
        if let chan = currentChannelId,
           let oldEnd = Int(currentBlock?.endEvent ?? "") {
            channelCursors[chan] = oldEnd
            logger.debug("cursor[\(chan)] = \(oldEnd) (swap to prefetched)")
        }
        prefetchedBlock = nil
        let songs = BlockSongs.orderedSongs(from: block)
        let swapStarts = BlockSongs.startsAtSeconds(songs: songs)
        logger.info("swap to prefetched block:\n\(describeBlock(url: block.url, songs: songs, starts: swapStarts))")
        currentBlock = block
        orderedSongs = songs
        startsAt = swapStarts
        currentSongIndex = 0
        let startPos = block.cue > 0 ? Double(block.cue) / 1000.0 : 0
        currentPositionSeconds = startPos
        guard let url = URL(string: block.url) else {
            logger.error("prefetched block had invalid url: \(block.url)")
            return
        }
        let startSeconds: Double? = startPos > 0 ? startPos : nil
        logger.debug("swap engine.play url=\(url.absoluteString) startSeconds=\(startSeconds.map { "\($0)s" } ?? "nil")")
        do {
            try await engine.play(url: url, startSeconds: startSeconds)
        } catch {
            logger.error("failed to play prefetched block: \(error)")
            return
        }
        emitNowPlaying(forSongIndex: 0)
    }
}

extension PlaybackCoordinatorError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .notPlaying:
            return "Playback is not currently active."
        case .channelNotFound(let channelId):
            return "Channel \(channelId) was not found."
        case .blockHasNoSongs:
            return "Stream block contained no songs."
        case .engineError(let message):
            return "Audio engine error: \(message)"
        case .underlying(let message):
            return message
        }
    }
}

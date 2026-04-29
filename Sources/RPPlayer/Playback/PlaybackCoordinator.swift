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
    private let bitrate: Int

    private var currentChannelId: Int?
    private var currentBlock: GetBlock?
    private var orderedSongs: [PlayListSong] = []
    private var startsAt: [Double] = []
    private var currentSongIndex: Int = 0
    private var currentPositionSeconds: Double = 0
    private var current: NowPlaying?
    private var continuations: [UUID: AsyncStream<NowPlaying>.Continuation] = [:]
    private var eventTask: Task<Void, Never>?
    private var pendingCueSeekSeconds: Double?
    private var prefetchedBlock: GetBlock?
    private var prefetchTask: Task<Void, Never>?
    private var isShutdown = false

    public init(
        api: any RpApiClient,
        engine: any PlayerEngine,
        logger: any Logging,
        bitrate: Int
    ) {
        self.api = api
        self.engine = engine
        self.logger = logger
        self.bitrate = bitrate
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
        await ensureEventSubscription()
        let block = try await api.getBlock(channel: channelId, bitrate: bitrate, info: false)
        let songs = BlockSongs.orderedSongs(from: block)
        guard !songs.isEmpty else { throw PlaybackCoordinatorError.blockHasNoSongs }

        currentChannelId = channelId
        currentBlock = block
        orderedSongs = songs
        startsAt = BlockSongs.startsAtSeconds(songs: songs)
        currentSongIndex = 0
        currentPositionSeconds = 0
        pendingCueSeekSeconds = block.cue > 0 ? Double(block.cue) / 1000.0 : nil

        guard let url = URL(string: block.url) else {
            throw PlaybackCoordinatorError.engineError(message: "invalid block url: \(block.url)")
        }
        do {
            try await engine.play(url: url)
        } catch {
            throw PlaybackCoordinatorError.engineError(message: String(describing: error))
        }
        emitNowPlaying(forSongIndex: 0)
    }

    public func pause() async throws {
        guard currentBlock != nil else { throw PlaybackCoordinatorError.notPlaying }
        do { try await engine.pause() } catch { throw PlaybackCoordinatorError.engineError(message: String(describing: error)) }
    }

    public func resume() async throws {
        guard currentBlock != nil else { throw PlaybackCoordinatorError.notPlaying }
        do { try await engine.resume() } catch { throw PlaybackCoordinatorError.engineError(message: String(describing: error)) }
    }

    public func stop() async throws {
        prefetchTask?.cancel()
        prefetchTask = nil
        prefetchedBlock = nil
        do { try await engine.stop() } catch { throw PlaybackCoordinatorError.engineError(message: String(describing: error)) }
        currentBlock = nil
        orderedSongs = []
        startsAt = []
        currentSongIndex = 0
        currentPositionSeconds = 0
        current = nil
    }

    public func skipForward() async throws {
        guard currentBlock != nil, !orderedSongs.isEmpty,
              let channelId = currentChannelId else {
            throw PlaybackCoordinatorError.notPlaying
        }
        let nextIndex = currentSongIndex + 1
        if nextIndex < orderedSongs.count {
            // Seek slightly past the boundary so positionUpdate trips into the new song.
            let target = startsAt[nextIndex] + 0.05
            do {
                try await engine.seek(to: target)
            } catch {
                throw PlaybackCoordinatorError.engineError(message: String(describing: error))
            }
            currentSongIndex = nextIndex
            currentPositionSeconds = target
            emitNowPlaying(forSongIndex: nextIndex)
        } else {
            // Past the last song — fetch a fresh block from the same channel
            // and play from offset 0 (no cue tune-in: user's intent is "next block").
            let block = try await api.getBlock(channel: channelId, bitrate: bitrate, info: false)
            let songs = BlockSongs.orderedSongs(from: block)
            guard !songs.isEmpty else { throw PlaybackCoordinatorError.blockHasNoSongs }
            currentBlock = block
            orderedSongs = songs
            startsAt = BlockSongs.startsAtSeconds(songs: songs)
            currentSongIndex = 0
            currentPositionSeconds = 0
            pendingCueSeekSeconds = nil
            guard let url = URL(string: block.url) else {
                throw PlaybackCoordinatorError.engineError(message: "invalid block url: \(block.url)")
            }
            do {
                try await engine.play(url: url)
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
            if let cueSeconds = pendingCueSeekSeconds {
                pendingCueSeekSeconds = nil
                do {
                    try await engine.seek(to: cueSeconds)
                } catch {
                    logger.warn("post-load cue seek failed: \(error)")
                }
            }
        case .positionUpdate(let seconds):
            currentPositionSeconds = seconds
            guard !startsAt.isEmpty else { return }
            let newIndex = BlockSongs.indexOfSong(at: seconds, in: startsAt)
            if newIndex != currentSongIndex && newIndex < orderedSongs.count {
                currentSongIndex = newIndex
                emitNowPlaying(forSongIndex: newIndex)
            }
            maybeStartPrefetch()
        case .fileEnded(let reason):
            if case .eof = reason {
                await swapToPrefetchedBlockIfAvailable()
            }
        case .error(let message):
            logger.error("player engine reported error: \(message)")
        case .hogModeChanged, .outputDeviceChanged, .shutdown:
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
            songEndSeconds: songEnd
        )
        current = np
        for c in continuations.values { c.yield(np) }
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

        let api = self.api
        let bitrate = self.bitrate
        prefetchTask = Task { [weak self] in
            let result = try? await api.getBlock(channel: channelId, bitrate: bitrate, info: false)
            await self?.absorbPrefetchResult(result)
        }
    }

    private func absorbPrefetchResult(_ block: GetBlock?) {
        prefetchTask = nil
        if let block = block, BlockSongs.orderedSongs(from: block).isEmpty == false {
            prefetchedBlock = block
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
        prefetchedBlock = nil
        let songs = BlockSongs.orderedSongs(from: block)
        currentBlock = block
        orderedSongs = songs
        startsAt = BlockSongs.startsAtSeconds(songs: songs)
        currentSongIndex = 0
        currentPositionSeconds = 0
        pendingCueSeekSeconds = nil
        guard let url = URL(string: block.url) else {
            logger.error("prefetched block had invalid url: \(block.url)")
            return
        }
        do {
            try await engine.play(url: url)
        } catch {
            logger.error("failed to play prefetched block: \(error)")
            return
        }
        emitNowPlaying(forSongIndex: 0)
    }
}

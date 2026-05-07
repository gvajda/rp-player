import Foundation

public enum PlaybackState: Sendable, Equatable {
    case stopped
    case playing
    case paused
}

public protocol PlaybackCoordinator: Sendable {
    var nowPlaying: NowPlaying? { get async }
    var nowPlayingUpdates: AsyncStream<NowPlaying> { get async }
    var positionUpdates: AsyncStream<Double> { get async }
    var stateUpdates: AsyncStream<PlaybackState> { get async }
    var currentPlaybackState: PlaybackState { get async }
    var errors: AsyncStream<String> { get async }

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
    private let clock: @Sendable () -> Date
    private let prefetchArt: @Sendable (String) -> Void
    private var pausedAt: Date? = nil
    private var pausePositionMs: Int = 0

    private var currentChannelId: Int?
    private var currentBlock: GetBlock?
    private var orderedSongs: [PlayListSong] = []
    private var startsAt: [Double] = []
    private var currentSongIndex: Int = 0
    private var currentPositionSeconds: Double = 0
    private var current: NowPlaying?
    private var continuations: [UUID: AsyncStream<NowPlaying>.Continuation] = [:]
    private var positionContinuations: [UUID: AsyncStream<Double>.Continuation] = [:]
    private var stateContinuations: [UUID: AsyncStream<PlaybackState>.Continuation] = [:]
    private var currentState: PlaybackState = .stopped
    private var eventTask: Task<Void, Never>?
    private var prefetchedBlock: GetBlock?
    private var prefetchTask: Task<Void, Never>?
    private var queuedToEngine: Bool = false
    private var isShutdown = false
    private var errorsContinuation: AsyncStream<String>.Continuation?
    private var consecutivePlaybackFailures = 0
    private static let maxConsecutivePlaybackFailures = 3
    // 59m, just under typical 1h CDN TCP idle eviction; observed mpv stream-end after 8.5h pause.
    private static let longIdleResumeThresholdSeconds: TimeInterval = 59 * 60

    public var errors: AsyncStream<String>

    private let onDeviceUnavailable: (@Sendable () async -> Void)?
    private let prePlayHook: @Sendable () async -> Void

    public init(
        api: any RpApiClient,
        engine: any PlayerEngine,
        logger: any Logging,
        bitrateProvider: @escaping @Sendable () async -> Int,
        clock: @escaping @Sendable () -> Date = { Date() },
        prefetchArt: @escaping @Sendable (String) -> Void = { _ in },
        onDeviceUnavailable: (@Sendable () async -> Void)? = nil,
        prePlayHook: @escaping @Sendable () async -> Void = {}
    ) {
        self.api = api
        self.engine = engine
        self.logger = logger
        self.bitrateProvider = bitrateProvider
        self.clock = clock
        self.prefetchArt = prefetchArt
        self.onDeviceUnavailable = onDeviceUnavailable
        self.prePlayHook = prePlayHook
        var cont: AsyncStream<String>.Continuation!
        self.errors = AsyncStream { cont = $0 }
        self.errorsContinuation = cont
    }

    public var nowPlaying: NowPlaying? { current }
    public var currentPlaybackState: PlaybackState { currentState }

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

    public var positionUpdates: AsyncStream<Double> {
        let id = UUID()
        return AsyncStream { continuation in
            if self.isShutdown { continuation.finish(); return }
            self.positionContinuations[id] = continuation
            continuation.yield(self.currentPositionSeconds)
            continuation.onTermination = { [weak self] _ in
                Task { [weak self] in await self?.unregisterPosition(id: id) }
            }
        }
    }

    public var stateUpdates: AsyncStream<PlaybackState> {
        let id = UUID()
        return AsyncStream { continuation in
            if self.isShutdown { continuation.finish(); return }
            self.stateContinuations[id] = continuation
            continuation.yield(self.currentState)
            continuation.onTermination = { [weak self] _ in
                Task { [weak self] in await self?.unregisterState(id: id) }
            }
        }
    }

    private func emitState(_ state: PlaybackState) {
        guard state != currentState else { return }
        currentState = state
        for c in stateContinuations.values { c.yield(state) }
    }

    public func play(channelId: Int) async throws {
        logger.debug("play(channelId: \(channelId))")
        await ensureEventSubscription()
        let bitrate = await bitrateProvider()
        logger.debug("play resolved bitrate=\(bitrate)")
        var block = try await api.play(
            channel: channelId, bitrate: bitrate, event: 0, action: .start,
            audioType: nil, episodeId: nil, sliceNum: nil
        )
        var songs = BlockSongs.orderedSongs(from: block)
        guard !songs.isEmpty else { throw PlaybackCoordinatorError.blockHasNoSongs }

        if BlockSongs.isStale(songs: songs, cue: block.cue) {
            let lastSong = songs.last
            let lastEvent: Int = Int(lastSong?.event ?? "") ?? Int(block.endEvent ?? "") ?? 0
            let audioType = lastSong?.type ?? "M"
            let sliceNum = lastSong?.sliceNum
            logger.info("bootstrap returned stale block (cue=0, all elapsed<=0); advancing via action=play event=\(lastEvent) audioType=\(audioType) sliceNum=\(sliceNum ?? "null")")
            block = try await api.play(
                channel: channelId, bitrate: bitrate, event: lastEvent, action: .play,
                audioType: audioType, episodeId: 0, sliceNum: sliceNum
            )
            songs = BlockSongs.orderedSongs(from: block)
            guard !songs.isEmpty else { throw PlaybackCoordinatorError.blockHasNoSongs }
        }

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
        // Acquire hog (when enabled) BEFORE mpv opens its CoreAudio AO. Otherwise
        // mpv's shared-mode AO can race with hog acquisition and end up registered
        // but silent — the user sees the progress bar advance but hears nothing
        // until pause+play forces an AO recreate.
        await prePlayHook()
        do {
            try await engine.play(url: url, startSeconds: startSeconds)
        } catch {
            throw PlaybackCoordinatorError.engineError(message: String(describing: error))
        }
        emitNowPlaying(forSongIndex: 0)
        emitState(.playing)
        fireSongStartTelemetry(song: orderedSongs[0], channelId: channelId)
    }

    public func pause() async throws {
        logger.debug("pause()")
        guard currentBlock != nil else { throw PlaybackCoordinatorError.notPlaying }
        do { try await engine.pause() } catch { throw PlaybackCoordinatorError.engineError(message: String(describing: error)) }
        emitState(.paused)
        pausedAt = clock()
        if currentSongIndex < startsAt.count {
            pausePositionMs = max(1, Int((currentPositionSeconds - startsAt[currentSongIndex]) * 1000))
        }
        guard currentSongIndex < orderedSongs.count,
              let channelId = currentChannelId else { return }
        let song = orderedSongs[currentSongIndex]
        guard song.type != "P" else { return }
        let ppm = pausePositionMs
        let ts = Int(clock().timeIntervalSince1970)
        let songId = song.songId
        let event = song.event ?? ""
        let audioType = song.type ?? "M"
        let sliceNum = song.sliceNum
        let api = self.api
        Task.detached {
            try? await api.updatePause(
                songId: songId, chan: channelId, event: event, audioType: audioType,
                sliceNum: sliceNum, playPositionMillis: ppm, playtimeSecs: ts
            )
        }
    }

    public func resume() async throws {
        logger.debug("resume()")
        guard let block = currentBlock else { throw PlaybackCoordinatorError.notPlaying }
        let now = clock()
        let pausedFor: TimeInterval? = pausedAt.map { now.timeIntervalSince($0) }
        let longIdle = (pausedFor ?? 0) >= Self.longIdleResumeThresholdSeconds
        let blockExpired = block.expiration > 0 && now.timeIntervalSince1970 > Double(block.expiration)
        if (longIdle || blockExpired), let channelId = currentChannelId {
            if longIdle {
                logger.info("resume: long idle (\(Int(pausedFor ?? 0))s >= \(Int(Self.longIdleResumeThresholdSeconds))s), refetching block")
            } else {
                logger.info("resume: block expired (now=\(Int(now.timeIntervalSince1970)) > expiration=\(block.expiration)), refetching")
            }
            try? await engine.clearPlaylist()
            queuedToEngine = false
            pausedAt = nil
            pausePositionMs = 0
            try await play(channelId: channelId)
            return
        }
        logger.debug("resume: block fresh, engine.resume()")
        await prePlayHook()
        do { try await engine.resume() } catch { throw PlaybackCoordinatorError.engineError(message: String(describing: error)) }
        emitState(.playing)
        guard pausedAt != nil, let channelId = currentChannelId,
              currentSongIndex < orderedSongs.count else { return }
        let song = orderedSongs[currentSongIndex]
        guard song.type != "P" else {
            pausedAt = nil
            pausePositionMs = 0
            return
        }
        let ppm = pausePositionMs
        let ts = Int(clock().timeIntervalSince1970)
        let songId = song.songId
        let event = song.event ?? ""
        let audioType = song.type ?? "M"
        let sliceNum = song.sliceNum
        let api = self.api
        pausedAt = nil
        pausePositionMs = 0
        Task.detached {
            try? await api.updateHistory(
                songId: songId, chan: channelId, event: event, audioType: audioType,
                sliceNum: sliceNum, playPositionMillis: ppm, playtimeSecs: ts,
                pauseFlag: true
            )
        }
    }

    public func stop() async throws {
        logger.debug("stop()")
        try? await engine.clearPlaylist()
        // Clear coordinator state BEFORE awaiting engine.stop. If we cleared
        // afterwards, a queued positionUpdate event processed during the
        // engine.stop suspension would see the still-active orderedSongs and
        // could spawn a fresh prefetch task that survives the cleanup.
        prefetchTask?.cancel()
        prefetchTask = nil
        prefetchedBlock = nil
        queuedToEngine = false
        currentBlock = nil
        orderedSongs = []
        startsAt = []
        currentSongIndex = 0
        currentPositionSeconds = 0
        pausedAt = nil
        pausePositionMs = 0
        current = nil
        do { try await engine.stop() } catch { throw PlaybackCoordinatorError.engineError(message: String(describing: error)) }
        emitState(.stopped)
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
            do {
                try await engine.seek(to: target)
            } catch {
                throw PlaybackCoordinatorError.engineError(message: String(describing: error))
            }
            currentSongIndex = nextIndex
            currentPositionSeconds = target
            emitNowPlaying(forSongIndex: nextIndex)
            fireSongStartTelemetry(song: nextSong, channelId: channelId, ppm: 1)
        } else {
            let lastSong = orderedSongs.last
            let lastEvent: Int = Int(lastSong?.event ?? "") ?? Int(currentBlock?.endEvent ?? "") ?? 0
            if queuedToEngine, prefetchedBlock != nil {
                logger.debug("skipForward past-last: advancing via engine.advanceToQueued (queued block ready)")
                do {
                    try await engine.advanceToQueued()
                } catch {
                    throw PlaybackCoordinatorError.engineError(message: String(describing: error))
                }
                return
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
            let audioType = lastSong?.type ?? "M"
            let sliceNum = lastSong?.sliceNum
            logger.debug("skipForward past last song, fetching next block channel=\(channelId) bitrate=\(bitrate) event=\(lastEvent) audioType=\(audioType) sliceNum=\(sliceNum ?? "null")")
            let block = try await api.play(
                channel: channelId, bitrate: bitrate, event: lastEvent, action: .play,
                audioType: audioType, episodeId: 0, sliceNum: sliceNum
            )
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
            fireSongStartTelemetry(song: songs[0], channelId: channelId, ppm: 1)
        }
    }

    public func changeChannel(to channelId: Int) async throws {
        try? await engine.clearPlaylist()
        prefetchTask?.cancel()
        prefetchTask = nil
        prefetchedBlock = nil
        queuedToEngine = false
        try await stop()
        try await play(channelId: channelId)
    }

    public func shutdown() async {
        guard !isShutdown else { return }
        isShutdown = true
        eventTask?.cancel()
        await eventTask?.value
        eventTask = nil
        // Click-on-quit fix: mute mpv (which feeds zeros to the AudioUnit),
        // give the AudioUnit's buffer a moment to drain into silence, then
        // terminate mpv cleanly. A bare stop / process exit hard-cuts the
        // AudioUnit mid-buffer and produces an audible pop on some DACs.
        try? await engine.setMute(true)
        try? await Task.sleep(nanoseconds: 150_000_000)
        await engine.shutdown()
        for c in continuations.values { c.finish() }
        continuations.removeAll()
        for c in positionContinuations.values { c.finish() }
        positionContinuations.removeAll()
        for c in stateContinuations.values { c.finish() }
        stateContinuations.removeAll()
        errorsContinuation?.finish()
        errorsContinuation = nil
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
            consecutivePlaybackFailures = 0
        case .fileStarted:
            if queuedToEngine {
                logger.debug("gapless transition: file started, swapping coordinator state")
                await swapToPrefetchedBlockState()
            }
        case .positionUpdate(let seconds):
            currentPositionSeconds = seconds
            for c in positionContinuations.values { c.yield(seconds) }
            guard !startsAt.isEmpty else { return }
            let newIndex = BlockSongs.indexOfSong(at: seconds, in: startsAt)
            if newIndex != currentSongIndex {
                logger.debug("song boundary crossed: \(currentSongIndex) -> \(newIndex) at pos=\(seconds)")
                currentSongIndex = newIndex
                emitNowPlaying(forSongIndex: newIndex)
                if let channelId = currentChannelId {
                    fireSongStartTelemetry(song: orderedSongs[newIndex], channelId: channelId)
                }
            }
            maybeStartPrefetch()
        case .fileEnded(let reason):
            logger.debug("engine fileEnded: \(reason)")
            if case .eof = reason {
                if queuedToEngine {
                    logger.debug("eof with queued block: mpv auto-advances; deferring state swap to fileStarted")
                } else {
                    await swapToPrefetchedBlockIfAvailable()
                }
            }
            if case .error(let code) = reason {
                if Self.isUnplayableBlockCode(code) {
                    await advancePastUnplayableBlock(failureCode: code)
                } else {
                    await handlePlaybackError(code: code)
                }
            }
        case .error(let message):
            logger.error("player engine reported error: \(message)")
        case .outputDeviceChanged, .shutdown:
            break
        }
    }

    private func handlePlaybackError(code: Int) async {
        logger.error("engine fileEnded with error code \(code)")
        try? await engine.clearPlaylist()
        prefetchTask?.cancel()
        prefetchTask = nil
        prefetchedBlock = nil
        queuedToEngine = false
        currentChannelId = nil
        currentBlock = nil
        orderedSongs = []
        startsAt = []
        currentSongIndex = 0
        currentPositionSeconds = 0
        pausedAt = nil
        pausePositionMs = 0
        current = nil
        let message = code == -14
            ? "Audio device unavailable. Hog mode + Force Max Volume turned off so the next device you pick can't surprise you. Check System Settings → Sound → Output."
            : "Playback stopped unexpectedly (error \(code))."
        emitState(.stopped)
        errorsContinuation?.yield(message)
        // Hearing-safety: when the chosen device went away (mpv code -14), drop
        // hog mode AND force-max so picking a fallback device (e.g. built-in
        // speakers) doesn't slam them at 100%. The handler is provided by
        // AppContainer and writes the settings + releases hog.
        if code == -14, let handler = onDeviceUnavailable {
            await handler()
        }
    }

    // mpv error codes that mean "this specific file/block is unplayable" (bad
    // container, format-detection failure, empty body, etc.) rather than a
    // device/system problem. Observed in the wild: -16 NOTHING_TO_PLAY on a
    // 5 s promo .m4a returned by api/play. Wiping all state on these errors
    // strands the user on the same channel because the server cursor still
    // points at the broken block on the next bootstrap.
    private static func isUnplayableBlockCode(_ code: Int) -> Bool {
        return code == -13 // LOADING_FAILED
            || code == -16 // NOTHING_TO_PLAY
            || code == -17 // UNKNOWN_FORMAT
            || code == -18 // UNSUPPORTED
    }

    private func advancePastUnplayableBlock(failureCode: Int) async {
        consecutivePlaybackFailures += 1
        guard consecutivePlaybackFailures <= Self.maxConsecutivePlaybackFailures else {
            logger.error("too many consecutive unplayable blocks (\(consecutivePlaybackFailures)); surfacing error \(failureCode)")
            await handlePlaybackError(code: failureCode)
            return
        }
        guard let channelId = currentChannelId, let block = currentBlock else {
            await handlePlaybackError(code: failureCode)
            return
        }

        let lastSong = orderedSongs.last
        let lastEvent: Int = Int(lastSong?.event ?? "") ?? Int(block.endEvent ?? "") ?? 0
        let audioType = lastSong?.type ?? "M"
        let sliceNum = lastSong?.sliceNum

        try? await engine.clearPlaylist()
        prefetchTask?.cancel()
        prefetchTask = nil
        prefetchedBlock = nil
        queuedToEngine = false

        logger.info("advancing past unplayable block (code \(failureCode)): channel=\(channelId) event=\(lastEvent) audioType=\(audioType) sliceNum=\(sliceNum ?? "null") attempt=\(consecutivePlaybackFailures)/\(Self.maxConsecutivePlaybackFailures)")
        do {
            let bitrate = await bitrateProvider()
            let nextBlock = try await api.play(
                channel: channelId, bitrate: bitrate, event: lastEvent, action: .play,
                audioType: audioType, episodeId: 0, sliceNum: sliceNum
            )
            let songs = BlockSongs.orderedSongs(from: nextBlock)
            guard !songs.isEmpty else {
                await handlePlaybackError(code: failureCode)
                return
            }
            let newStarts = BlockSongs.startsAtSeconds(songs: songs)
            currentBlock = nextBlock
            orderedSongs = songs
            startsAt = newStarts
            currentSongIndex = 0
            let startPos = nextBlock.cue > 0 ? Double(nextBlock.cue) / 1000.0 : 0
            currentPositionSeconds = startPos
            guard let url = URL(string: nextBlock.url) else {
                await handlePlaybackError(code: failureCode)
                return
            }
            let startSeconds: Double? = startPos > 0 ? startPos : nil
            try await engine.play(url: url, startSeconds: startSeconds)
            emitNowPlaying(forSongIndex: 0)
            fireSongStartTelemetry(song: songs[0], channelId: channelId, ppm: 1)
        } catch {
            logger.error("advance past unplayable block failed: \(error)")
            await handlePlaybackError(code: failureCode)
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
        prefetchUpcomingSongArt()
        maybeStartPrefetch()
    }

    // Warm the album-art cache for the song that will play next so the popover
    // doesn't show a blank tile during the cross-fade. Within a block we know
    // the next song from orderedSongs; at the end of the block we use the
    // already-prefetched next block if it has arrived.
    private func prefetchUpcomingSongArt() {
        let nextIndex = currentSongIndex + 1
        if nextIndex < orderedSongs.count {
            if let cover = orderedSongs[nextIndex].cover, !cover.isEmpty {
                prefetchArt(cover)
            }
        } else if let prefetched = prefetchedBlock,
                  let cover = BlockSongs.orderedSongs(from: prefetched).first?.cover,
                  !cover.isEmpty {
            prefetchArt(cover)
        }
    }

    private func fireSongStartTelemetry(song: PlayListSong, channelId: Int, ppm: Int? = nil) {
        guard song.type != "P" else { return }
        guard currentSongIndex < startsAt.count else { return }
        let resolvedPpm = ppm ?? max(1, Int((currentPositionSeconds - startsAt[currentSongIndex]) * 1000))
        let ts = Int(clock().timeIntervalSince1970)
        let songId = song.songId
        let event = song.event ?? ""
        let audioType = song.type ?? "M"
        let sliceNum = song.sliceNum
        let api = self.api
        Task.detached {
            try? await api.updateHistory(
                songId: songId, chan: channelId, event: event, audioType: audioType,
                sliceNum: sliceNum, playPositionMillis: resolvedPpm, playtimeSecs: ts,
                pauseFlag: false
            )
        }
    }

    private func describeBlock(url: String, songs: [PlayListSong], starts: [Double]) -> String {
        let lines = songs.enumerated().map { i, song in
            String(format: "  [%d] %7.1fs  %@ – %@ (%.1fs)", i, starts[i], song.artist, song.title, Double(song.duration) / 1000.0)
        }
        return "url=\(url)\n" + lines.joined(separator: "\n")
    }

    private func unregister(id: UUID) { continuations.removeValue(forKey: id) }
    private func unregisterPosition(id: UUID) { positionContinuations.removeValue(forKey: id) }
    private func unregisterState(id: UUID) { stateContinuations.removeValue(forKey: id) }

    private func maybeStartPrefetch() {
        guard let channelId = currentChannelId,
              !orderedSongs.isEmpty,
              currentSongIndex == orderedSongs.count - 1,
              prefetchedBlock == nil,
              prefetchTask == nil else { return }

        let lastSong = orderedSongs.last
        let lastEvent: Int = Int(lastSong?.event ?? "") ?? Int(currentBlock?.endEvent ?? "") ?? 0
        let audioType = lastSong?.type ?? "M"
        let sliceNum = lastSong?.sliceNum
        let api = self.api
        let provider = self.bitrateProvider
        prefetchTask = Task { [weak self, logger] in
            let bitrate = await provider()
            logger.debug("prefetch start, channel=\(channelId) bitrate=\(bitrate) event=\(lastEvent) audioType=\(audioType) sliceNum=\(sliceNum ?? "null")")
            let result = try? await api.play(
                channel: channelId, bitrate: bitrate, event: lastEvent, action: .play,
                audioType: audioType, episodeId: 0, sliceNum: sliceNum
            )
            await self?.absorbPrefetchResult(result)
        }
    }

    private func absorbPrefetchResult(_ block: GetBlock?) async {
        // If cleanup (stop / changeChannel) ran during the fetch, prefetchTask
        // was nilled — discard the late result so we don't resurrect a stale block.
        guard prefetchTask != nil else { return }
        prefetchTask = nil
        if let block = block, BlockSongs.orderedSongs(from: block).isEmpty == false {
            // Defense: only queue when a current block is still active. If channelChange
            // wiped state during the fetch, the queued URL would belong to a different channel.
            guard currentBlock != nil else { return }
            prefetchedBlock = block
            logger.debug("prefetch absorbed: url=\(block.url)")
            if let cover = BlockSongs.orderedSongs(from: block).first?.cover,
               !cover.isEmpty {
                prefetchArt(cover)
            }
            let startPos = block.cue > 0 ? Double(block.cue) / 1000.0 : 0
            let startSeconds: Double? = startPos > 0 ? startPos : nil
            guard let url = URL(string: block.url) else { return }
            do {
                try await engine.queueNext(url: url, startSeconds: startSeconds)
                queuedToEngine = true
                logger.debug("queued next block on engine: url=\(url.absoluteString) start=\(startSeconds.map { "\($0)s" } ?? "nil")")
            } catch {
                queuedToEngine = false
                logger.error("engine.queueNext failed: \(error). EOF will use replace fallback.")
            }
        }
    }

    private func swapToPrefetchedBlockState() async {
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
        queuedToEngine = false
        let songs = BlockSongs.orderedSongs(from: block)
        let swapStarts = BlockSongs.startsAtSeconds(songs: songs)
        logger.info("swap to prefetched block:\n\(describeBlock(url: block.url, songs: songs, starts: swapStarts))")
        currentBlock = block
        orderedSongs = songs
        startsAt = swapStarts
        currentSongIndex = 0
        let startPos = block.cue > 0 ? Double(block.cue) / 1000.0 : 0
        currentPositionSeconds = startPos
        emitNowPlaying(forSongIndex: 0)
        if let channelId = currentChannelId {
            fireSongStartTelemetry(song: orderedSongs[0], channelId: channelId)
        }
    }

    private func swapToPrefetchedBlockIfAvailable() async {
        let hadPrefetched = prefetchedBlock != nil
        await swapToPrefetchedBlockState()
        guard hadPrefetched, let block = currentBlock else { return }
        guard let url = URL(string: block.url) else {
            logger.error("prefetched block had invalid url: \(block.url)")
            return
        }
        let startPos = block.cue > 0 ? Double(block.cue) / 1000.0 : 0
        let startSeconds: Double? = startPos > 0 ? startPos : nil
        logger.debug("swap engine.play url=\(url.absoluteString) startSeconds=\(startSeconds.map { "\($0)s" } ?? "nil")")
        do {
            try await engine.play(url: url, startSeconds: startSeconds)
        } catch {
            logger.error("failed to play prefetched block: \(error)")
        }
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

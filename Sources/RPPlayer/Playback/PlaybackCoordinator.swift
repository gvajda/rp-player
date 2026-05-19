import Foundation

public enum PlaybackState: Sendable, Equatable {
    case stopped
    case loading
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
    func applyBitrateChange() async
    func shutdown() async
}

public actor LivePlaybackCoordinator: PlaybackCoordinator {
    private let api: any RpApiClient
    private let engine: any PlayerEngine
    private let songFileCache: any SongFileCache
    private let logger: any Logging
    private let bitrateProvider: @Sendable () async -> Int
    private let clock: @Sendable () -> Date
    private let prefetchArt: @Sendable (String) -> Void
    private var pausedAt: Date? = nil
    private var pausePositionMs: Int = 0

    private var currentChannelId: Int?
    private var queue: [GaplessSong] = []
    private var currentResponse: GaplessResponse?
    // mpv may fire MPV_EVENT_START_FILE multiple times around state transitions (initial load + auto-advance + replace).
    // We trust mpv's `path` property as ground truth and dedupe START_FILE events by the song's eventId.
    private var lastStartedEventId: Int?
    // eventId of the song currently queueNext'd in mpv's playlist (queue[1] under normal flow).
    // Cleared on every clearPlaylist. Set after every successful engine.queueNext.
    // Used by skipForward to detect "queue[1] is in memory but not yet pre-queued in mpv"
    // (the inline localFile await after engine.play hasn't completed yet), so we can
    // show the loading state during the wait instead of advancing to an empty playlist.
    private var queueNextEventId: Int?
    private var currentPositionSeconds: Double = 0
    private var current: NowPlaying?
    private var continuations: [UUID: AsyncStream<NowPlaying>.Continuation] = [:]
    private var positionContinuations: [UUID: AsyncStream<Double>.Continuation] = [:]
    private var stateContinuations: [UUID: AsyncStream<PlaybackState>.Continuation] = [:]
    private var currentState: PlaybackState = .stopped
    private var eventTask: Task<Void, Never>?
    private var refetchTask: Task<Void, Never>?
    private var downloaderTask: Task<Void, Never>?
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
        songFileCache: any SongFileCache,
        logger: any Logging,
        bitrateProvider: @escaping @Sendable () async -> Int,
        clock: @escaping @Sendable () -> Date = { Date() },
        prefetchArt: @escaping @Sendable (String) -> Void = { _ in },
        onDeviceUnavailable: (@Sendable () async -> Void)? = nil,
        prePlayHook: @escaping @Sendable () async -> Void = {}
    ) {
        self.api = api
        self.engine = engine
        self.songFileCache = songFileCache
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

    func snapshotQueueIds() -> [Int] { queue.map { $0.eventId } }

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
        emitState(.loading)
        do {
            try await playInternal(channelId: channelId)
        } catch {
            emitState(.stopped)
            throw error
        }
    }

    private func playInternal(channelId: Int) async throws {
        await ensureEventSubscription()
        let bitrate = await bitrateProvider()
        logger.debug("play resolved bitrate=\(bitrate)")
        let response = try await api.gapless(channel: channelId, bitrate: bitrate, numSongs: 20)
        guard !response.songs.isEmpty else { throw PlaybackCoordinatorError.blockHasNoSongs }

        queue = response.songs
        currentResponse = response
        currentChannelId = channelId
        refetchTask?.cancel()
        refetchTask = nil

        let head = queue[0]
        // Always start songs from the beginning; ignore server-provided cue. Better UX (full song) than mid-song tune-in; user can skip if not wanted.
        let startSeconds: Double? = nil
        currentPositionSeconds = 0

        let resolvedHeadUrl = await songFileCache.localFile(for: head)
            ?? URL(string: head.gaplessUrl)
        guard let url = resolvedHeadUrl else {
            throw PlaybackCoordinatorError.engineError(message: "invalid gapless url: \(head.gaplessUrl)")
        }

        logger.debug("play queue:\n\(describeQueue(songs: queue))")
        logger.debug("play engine.play url=\(url.absoluteString) startSeconds=\(startSeconds.map { "\($0)s" } ?? "nil (beginning)") (cache hit=\(url.isFileURL))")

        // Acquire hog (when enabled) BEFORE mpv opens its CoreAudio AO. Otherwise
        // mpv's shared-mode AO can race with hog acquisition and end up registered
        // but silent — the user sees the progress bar advance but hears nothing
        // until pause+play forces an AO recreate.
        await prePlayHook()
        lastStartedEventId = nil
        do {
            try await engine.play(url: url, startSeconds: startSeconds)
        } catch {
            throw PlaybackCoordinatorError.engineError(message: String(describing: error))
        }

        // Emit state before awaiting queue[1] download so UI exits .loading
        // the moment audio actually starts. The queue[1] download below can
        // take many seconds on slow networks and used to gate the spinner.
        emitNowPlaying(forSongAt: 0)
        emitState(.playing)

        if queue.count >= 2 {
            let next = queue[1]
            let nextUrl = await songFileCache.localFile(for: next)
                ?? URL(string: next.gaplessUrl)
            if let nextUrl {
                // Race-guard: another action (skip / channel-change) may have run
                // on this actor during the localFile await. queue[1] may no
                // longer match `next`. Only queueNext if it still does.
                if queue.count >= 2, queue[1].eventId == next.eventId {
                    do {
                        try await engine.queueNext(url: nextUrl, startSeconds: nil)
                        queueNextEventId = next.eventId
                    } catch {
                        logger.warn("play: queueNext failed: \(error)")
                    }
                }
            }
        }

        // Telemetry + queueNext for queue[1] are driven from syncQueueHeadFromMpv when mpv fires .fileStarted.
        if queue.count < 3 {
            kickRefetch()
        }
        kickSequentialDownload()
    }

    public func pause() async throws {
        logger.debug("pause()")
        guard !queue.isEmpty else { throw PlaybackCoordinatorError.notPlaying }
        do { try await engine.pause() } catch { throw PlaybackCoordinatorError.engineError(message: String(describing: error)) }
        emitState(.paused)
        pausedAt = clock()
        pausePositionMs = max(1, Int(currentPositionSeconds * 1000))
        guard let channelId = currentChannelId else { return }
        let song = queue[0]
        guard song.updateHistory else { return }
        let ppm = pausePositionMs
        let ts = Int(clock().timeIntervalSince1970)
        let songId = song.songId
        let event = String(song.eventId)
        let audioType = song.type
        let sliceNum = String(song.sliceNum)
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
        guard !queue.isEmpty, let channelId = currentChannelId else { throw PlaybackCoordinatorError.notPlaying }
        let now = clock()
        let pausedFor: TimeInterval? = pausedAt.map { now.timeIntervalSince($0) }
        let longIdle = (pausedFor ?? 0) >= Self.longIdleResumeThresholdSeconds

        // If queue[0]'s cached file was evicted during pause, mpv will fail re-opening
        // the file:// URL. Fall back to the legacy refetch+restart path.
        if longIdle && songFileCache.cachedFile(for: queue[0]) == nil {
            logger.warn("resume: cache miss for queue[0]; falling back to refetch+restart")
            try? await engine.clearPlaylist()
            queueNextEventId = nil
            queue = []
            currentResponse = nil
            lastStartedEventId = nil
            currentPositionSeconds = 0
            current = nil
            pausedAt = nil
            pausePositionMs = 0
            try await play(channelId: channelId)
            return
        }

        await prePlayHook()
        do { try await engine.resume() } catch { throw PlaybackCoordinatorError.engineError(message: String(describing: error)) }
        emitState(.playing)

        let song = queue[0]
        if pausedAt != nil, song.updateHistory {
            let ppm = pausePositionMs
            let ts = Int(clock().timeIntervalSince1970)
            let songId = song.songId
            let event = String(song.eventId)
            let audioType = song.type
            let sliceNum = String(song.sliceNum)
            let api = self.api
            Task.detached {
                try? await api.updateHistory(
                    songId: songId, chan: channelId, event: event, audioType: audioType,
                    sliceNum: sliceNum, playPositionMillis: ppm, playtimeSecs: ts,
                    pauseFlag: true
                )
            }
        }
        pausedAt = nil
        pausePositionMs = 0

        // Long-idle catch-up: drop stale tail beyond queue[1]; refetch in background.
        if longIdle {
            logger.info("resume: long idle (\(Int(pausedFor ?? 0))s), kicking background catch-up")
            if queue.count > 2 {
                queue = Array(queue.prefix(2))
            }
            // Stop downloading the old tail. New tail starts after refetch resolves.
            downloaderTask?.cancel()
            downloaderTask = nil
            await songFileCache.cancelInFlightDownloads()
            kickRefetch()
        }
    }

    public func stop() async throws {
        logger.debug("stop()")
        try? await engine.clearPlaylist()
        queueNextEventId = nil
        downloaderTask?.cancel()
        downloaderTask = nil
        await songFileCache.cancelInFlightDownloads()
        // Clear coordinator state BEFORE awaiting engine.stop. If we cleared
        // afterwards, a queued positionUpdate event processed during the
        // engine.stop suspension would see the still-active queue and could
        // spawn a fresh refetch task that survives the cleanup.
        refetchTask?.cancel()
        refetchTask = nil
        queue = []
        currentResponse = nil
        lastStartedEventId = nil
        queueNextEventId = nil
        currentChannelId = nil
        currentPositionSeconds = 0
        pausedAt = nil
        pausePositionMs = 0
        current = nil
        do { try await engine.stop() } catch { throw PlaybackCoordinatorError.engineError(message: String(describing: error)) }
        emitState(.stopped)
    }

    public func skipForward() async throws {
        logger.debug("skipForward at queueCount=\(queue.count), pos=\(currentPositionSeconds)")
        guard !queue.isEmpty, let channelId = currentChannelId else {
            throw PlaybackCoordinatorError.notPlaying
        }
        let skipped = queue[0]
        let playtime = max(1, Int(currentPositionSeconds.rounded()))
        if skipped.updateHistory {
            let api = self.api
            let songId = skipped.songId
            let event = String(skipped.eventId)
            let audioType = skipped.type
            let sliceNum = String(skipped.sliceNum)
            Task.detached {
                try? await api.updateHistory(
                    songId: songId, chan: channelId, event: event, audioType: audioType,
                    sliceNum: sliceNum, playPositionMillis: playtime * 1000,
                    playtimeSecs: playtime, pauseFlag: false
                )
            }
        }
        if queue.count >= 2 {
            // If queue[1] hasn't actually been queueNext'd in mpv yet (the inline
            // localFile await in play()/sync handler is still in flight), advancing
            // would jump to an empty playlist. Wait for the download + queueNext,
            // surfacing the loading state to the UI for the duration.
            if queueNextEventId != queue[1].eventId {
                logger.debug("skipForward: queue[1] not yet queued in mpv (queueNextEventId=\(queueNextEventId.map(String.init) ?? "nil"), queue[1].eventId=\(queue[1].eventId)); awaiting download")
                emitState(.loading)
                let next = queue[1]
                let nextUrl = await songFileCache.localFile(for: next)
                    ?? URL(string: next.gaplessUrl)
                // Race-guard: skipForward may have been called again or the
                // queue may have shifted during the await. Re-check.
                guard queue.count >= 2, queue[1].eventId == next.eventId,
                      let nextUrl else {
                    emitState(.playing)
                    return
                }
                // queueNextEventId may have been set by a concurrent path
                // (syncQueueHeadFromMpv); skip the queueNext if so.
                if queueNextEventId != next.eventId {
                    do {
                        try await engine.queueNext(url: nextUrl, startSeconds: nil)
                        queueNextEventId = next.eventId
                    } catch {
                        emitState(.playing)
                        throw PlaybackCoordinatorError.engineError(message: String(describing: error))
                    }
                }
                emitState(.playing)
            }
            logger.debug("skipForward: advancing to queued entry on engine")
            do {
                try await engine.advanceToQueued()
            } catch {
                throw PlaybackCoordinatorError.engineError(message: String(describing: error))
            }
            // The .fileStarted handler runs queue.removeFirst() + state advance.
            return
        }
        // Queue is shallow — synchronous refetch + restart.
        emitState(.loading)
        let bitrate = await bitrateProvider()
        let response: GaplessResponse
        do {
            response = try await api.gapless(channel: channelId, bitrate: bitrate, numSongs: 20)
        } catch {
            emitState(.playing)
            errorsContinuation?.yield("Cannot skip — try again.")
            return
        }
        guard !response.songs.isEmpty else {
            emitState(.playing)
            errorsContinuation?.yield("Cannot skip — no upcoming songs.")
            return
        }
        // Drop the skipped song; jump to the new response's first song.
        queue = response.songs
        currentResponse = response
        queueNextEventId = nil
        let head = queue[0]
        // Always start from the beginning; ignore cue.
        currentPositionSeconds = 0
        let resolvedHeadUrl = await songFileCache.localFile(for: head)
            ?? URL(string: head.gaplessUrl)
        guard let url = resolvedHeadUrl else {
            emitState(.playing)
            errorsContinuation?.yield("Cannot skip — invalid url.")
            return
        }
        let startSeconds: Double? = nil
        lastStartedEventId = nil
        do {
            try await engine.play(url: url, startSeconds: startSeconds)
        } catch {
            emitState(.stopped)
            errorsContinuation?.yield("Cannot skip — engine play failed.")
            return
        }
        emitNowPlaying(forSongAt: 0)
        emitState(.playing)
        if queue.count >= 2 {
            let next = queue[1]
            let nextUrl = await songFileCache.localFile(for: next)
                ?? URL(string: next.gaplessUrl)
            if let nextUrl, queue.count >= 2, queue[1].eventId == next.eventId {
                do {
                    try await engine.queueNext(url: nextUrl, startSeconds: nil)
                    queueNextEventId = next.eventId
                } catch {
                    logger.warn("skipForward shallow-refetch: queueNext failed: \(error)")
                }
            }
        }
        kickSequentialDownload()
        // Telemetry driven from syncQueueHeadFromMpv when mpv fires .fileStarted.
        if queue.count < 3 {
            kickRefetch()
        }
    }

    public func changeChannel(to channelId: Int) async throws {
        refetchTask?.cancel()
        refetchTask = nil
        try? await engine.clearPlaylist()
        queueNextEventId = nil
        downloaderTask?.cancel()
        downloaderTask = nil
        await songFileCache.cancelInFlightDownloads()
        try await stop()
        try await play(channelId: channelId)
    }

    /// Reload the queue from `api/gapless` at the current bitrate, keeping the
    /// in-flight song untouched and swapping the queued-next entry to the new
    /// bitrate URL so the change takes effect on the next song boundary
    /// instead of waiting for the 20-song queue to drain.
    public func applyBitrateChange() async {
        guard let channelId = currentChannelId, let head = queue.first else {
            logger.debug("applyBitrateChange: nothing playing, skip")
            return
        }
        let bitrate = await bitrateProvider()
        logger.debug("applyBitrateChange channel=\(channelId) bitrate=\(bitrate) headEvent=\(head.eventId)")
        refetchTask?.cancel()
        refetchTask = nil
        let response: GaplessResponse
        do {
            response = try await api.gapless(channel: channelId, bitrate: bitrate, numSongs: 20)
        } catch {
            logger.warn("applyBitrateChange failed: \(error)")
            return
        }
        guard self.currentChannelId == channelId,
              self.queue.first?.eventId == head.eventId else {
            logger.debug("applyBitrateChange: channel/head moved during fetch, discard")
            return
        }
        // Expect cursor to land on the still-playing song; warn if not (the
        // tail will still be valid, just the in-flight song's URL is the old
        // bitrate — which is fine, we don't restart it).
        if response.songs.first?.eventId != head.eventId {
            let serverHead = response.songs.first?.eventId.description ?? "nil"
            logger.warn("applyBitrateChange: server cursor at eventId=\(serverHead), expected \(head.eventId)")
        }
        let newSongs = response.songs.filter { $0.eventId > head.eventId }
        self.queue = [head] + newSongs
        self.currentResponse = response
        emitNowPlaying(forSongAt: 0)
        try? await engine.clearPlaylist()
        queueNextEventId = nil
        // Bitrate change minted new gaplessUrls. Cancel any in-flight downloader
        // walk so old-bitrate downloads stop stealing bandwidth from the new
        // bitrate's queue; on-disk old-bitrate files become orphans and the
        // LRU cap will reclaim them.
        downloaderTask?.cancel()
        downloaderTask = nil
        await songFileCache.cancelInFlightDownloads()
        if self.queue.count >= 2 {
            let next = self.queue[1]
            let nextUrl = await songFileCache.localFile(for: next)
                ?? URL(string: next.gaplessUrl)
            if let nextUrl, self.queue.count >= 2, self.queue[1].eventId == next.eventId {
                do {
                    try await engine.queueNext(url: nextUrl, startSeconds: nil)
                    queueNextEventId = next.eventId
                } catch {
                    logger.warn("applyBitrateChange: queueNext failed: \(error)")
                }
            }
        }
        if self.queue.count < 3 {
            kickRefetch()
        }
        kickSequentialDownload()
    }

    public func shutdown() async {
        guard !isShutdown else { return }
        isShutdown = true
        refetchTask?.cancel()
        refetchTask = nil
        downloaderTask?.cancel()
        downloaderTask = nil
        await songFileCache.cancelInFlightDownloads()
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
            logger.debug("engine fileStarted (mpv MPV_EVENT_START_FILE)")
            await syncQueueHeadFromMpv()

        case .positionUpdate(let seconds):
            currentPositionSeconds = seconds
            for c in positionContinuations.values { c.yield(seconds) }

        case .fileEnded(let reason):
            logger.debug("engine fileEnded: \(reason)")
            switch reason {
            case .eof:
                // mpv reached EOF without auto-advancing — refetch lagged. Recover.
                logger.warn("fileEnded(.eof) without queued entry; recovering")
                if queue.count >= 2 {
                    queue.removeFirst()
                    queueNextEventId = nil
                    let head = queue[0]
                    let resolvedHeadUrl = await songFileCache.localFile(for: head)
                        ?? URL(string: head.gaplessUrl)
                    if let url = resolvedHeadUrl {
                        do {
                            lastStartedEventId = nil
                            try await engine.play(url: url, startSeconds: nil)
                            currentPositionSeconds = 0
                            emitNowPlaying(forSongAt: 0)
                            // Telemetry driven from syncQueueHeadFromMpv when mpv fires .fileStarted.
                            if queue.count >= 2 {
                                let next = queue[1]
                                let nextUrl = await songFileCache.localFile(for: next)
                                    ?? URL(string: next.gaplessUrl)
                                if let nextUrl, queue.count >= 2, queue[1].eventId == next.eventId {
                                    do {
                                        try await engine.queueNext(url: nextUrl, startSeconds: nil)
                                        queueNextEventId = next.eventId
                                    } catch {
                                        logger.warn("fileEnded recovery: queueNext failed: \(error)")
                                    }
                                }
                            }
                            if queue.count < 3 { kickRefetch() }
                            kickSequentialDownload()
                            return
                        } catch {
                            await handlePlaybackError(code: -99)
                            return
                        }
                    }
                    await handlePlaybackError(code: -99)
                    return
                }
                // Queue depleted entirely. Refetch + retry.
                guard let channelId = currentChannelId else {
                    await handlePlaybackError(code: -99)
                    return
                }
                do {
                    try await play(channelId: channelId)
                } catch {
                    await handlePlaybackError(code: -99)
                }
            case .error(let code):
                if isUnplayableSongCode(code) && queue.count >= 2 {
                    await handleSongPlaybackError(code: code)
                } else {
                    await handlePlaybackError(code: code)
                }
            case .stopped, .quit, .redirect, .unknown:
                break
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
        queueNextEventId = nil
        downloaderTask?.cancel()
        downloaderTask = nil
        await songFileCache.cancelInFlightDownloads()
        refetchTask?.cancel()
        refetchTask = nil
        currentChannelId = nil
        queue = []
        currentResponse = nil
        lastStartedEventId = nil
        currentPositionSeconds = 0
        pausedAt = nil
        pausePositionMs = 0
        current = nil
        let nonDeviceMessage = "Playback stopped unexpectedly (error \(code))."
        emitState(.stopped)
        if code == -14, let handler = onDeviceUnavailable {
            // Handler decides the user message (preserve-when-hog vs hearing-safety reset).
            await handler()
        } else {
            errorsContinuation?.yield(nonDeviceMessage)
        }
    }

    // mpv error codes that mean "this specific song is unplayable" (bad
    // container, format-detection failure, empty body, etc.) rather than a
    // device/system problem. With the gapless model each song is a discrete
    // file; dropping a single broken song and continuing is safer than wiping
    // all state.
    private func isUnplayableSongCode(_ code: Int) -> Bool {
        return code == -13 // LOADING_FAILED
            || code == -16 // NOTHING_TO_PLAY
            || code == -17 // UNKNOWN_FORMAT
            || code == -18 // UNSUPPORTED
    }

    private func handleSongPlaybackError(code: Int) async {
        consecutivePlaybackFailures += 1
        guard consecutivePlaybackFailures <= Self.maxConsecutivePlaybackFailures else {
            logger.error("too many consecutive unplayable songs (\(consecutivePlaybackFailures)); surfacing error \(code)")
            await handlePlaybackError(code: code)
            return
        }
        guard !queue.isEmpty, let channelId = currentChannelId else {
            await handlePlaybackError(code: code)
            return
        }
        let dropped = queue.removeFirst()
        logger.warn("dropping unplayable song event=\(dropped.eventId) url=\(dropped.gaplessUrl) code=\(code) attempt=\(consecutivePlaybackFailures)/\(Self.maxConsecutivePlaybackFailures)")
        guard !queue.isEmpty else {
            // Queue depleted — refetch fresh.
            do {
                try await play(channelId: channelId)
            } catch {
                await handlePlaybackError(code: code)
            }
            return
        }
        let head = queue[0]
        let resolvedHeadUrl = await songFileCache.localFile(for: head)
            ?? URL(string: head.gaplessUrl)
        guard let url = resolvedHeadUrl else {
            await handlePlaybackError(code: code)
            return
        }
        do {
            lastStartedEventId = nil
            try await engine.play(url: url, startSeconds: nil)
        } catch {
            await handlePlaybackError(code: code)
            return
        }
        currentPositionSeconds = 0
        queueNextEventId = nil
        emitNowPlaying(forSongAt: 0)
        // Telemetry driven from syncQueueHeadFromMpv when mpv fires .fileStarted.
        if queue.count >= 2 {
            let next = queue[1]
            let nextUrl = await songFileCache.localFile(for: next)
                ?? URL(string: next.gaplessUrl)
            if let nextUrl, queue.count >= 2, queue[1].eventId == next.eventId {
                do {
                    try await engine.queueNext(url: nextUrl, startSeconds: nil)
                    queueNextEventId = next.eventId
                } catch {
                    logger.warn("handleSongPlaybackError: queueNext failed: \(error)")
                }
            }
        }
        if queue.count < 3 {
            kickRefetch()
        }
        kickSequentialDownload()
    }

    private func syncQueueHeadFromMpv() async {
        guard !queue.isEmpty else { return }
        let path = await engine.currentPath()
        // Locate mpv's actual playing URL in the queue. mpv may report either the
        // remote gaplessUrl (passthrough / fallback) or the local cache file path
        // (PR 32 normal path: download-then-play). Match against both.
        let idx: Int
        if let path {
            let cache = songFileCache
            let found = queue.firstIndex { song in
                if song.gaplessUrl == path { return true }
                // mpv reports the path without a file:// scheme; URL.path strips it too.
                return cache.expectedLocalPath(for: song).path == path
            }
            if let found {
                idx = found
            } else {
                logger.warn("syncQueueHead: mpv path \(path) not found in queue; falling back to queue[0]")
                idx = 0
            }
        } else {
            idx = 0
        }
        let head = queue[idx]
        // Dedupe: if this song's eventId matches the last one we observed starting, the START_FILE event is redundant.
        if let last = lastStartedEventId, last == head.eventId {
            return
        }
        let isAdvance = lastStartedEventId != nil
        // Drop everything before idx — those songs were skipped past or finished naturally.
        if idx > 0 {
            let dropped = Array(queue.prefix(idx))
            queue.removeFirst(idx)
            for finished in dropped where finished.updateHistory {
                if let channelId = currentChannelId {
                    let api = self.api
                    let songId = finished.songId
                    let event = String(finished.eventId)
                    let audioType = finished.type
                    let sliceNum = String(finished.sliceNum)
                    let durationMs = finished.duration
                    let playtime = max(1, Int(currentPositionSeconds.rounded()))
                    Task.detached {
                        try? await api.updateHistory(
                            songId: songId, chan: channelId, event: event, audioType: audioType,
                            sliceNum: sliceNum, playPositionMillis: durationMs,
                            playtimeSecs: playtime, pauseFlag: false
                        )
                    }
                }
            }
            // Evict dropped songs' cached files AFTER spawning telemetry so the cursor-advanced ordering is preserved.
            let cache = songFileCache
            Task { [dropped] in
                for song in dropped {
                    await cache.evict(song)
                }
            }
        }
        lastStartedEventId = queue[0].eventId
        currentPositionSeconds = 0
        let kind = isAdvance ? "advance" : "initial"
        logger.info("song.started (\(kind)) \(describeSong(queue[0]))")
        emitNowPlaying(forSongAt: 0)
        if let channelId = currentChannelId {
            fireSongStartTelemetry(song: queue[0], channelId: channelId)
        }
        // Only re-issue queueNext on advance — initial sync is preceded by play()/handleSongPlaybackError/etc which already queued queue[1].
        if isAdvance {
            // The old queueNext'd entry is now playing; mpv's playlist is empty
            // until we re-queue. Clear before the await so a concurrent skip
            // sees the right state.
            queueNextEventId = nil
            if queue.count >= 2 {
                let next = queue[1]
                let nextUrl = await songFileCache.localFile(for: next)
                    ?? URL(string: next.gaplessUrl)
                if let nextUrl, queue.count >= 2, queue[1].eventId == next.eventId {
                    do {
                        try await engine.queueNext(url: nextUrl, startSeconds: nil)
                        queueNextEventId = next.eventId
                    } catch {
                        logger.warn("syncQueueHead: queueNext failed: \(error)")
                    }
                }
            }
        }
        kickSequentialDownload()
        if queue.count < 3 {
            kickRefetch()
        }
    }

    private func emitNowPlaying(forSongAt index: Int) {
        guard index >= 0, index < queue.count, let channelId = currentChannelId else { return }
        let song = queue[index]
        let np = NowPlaying(
            channelId: channelId,
            song: song,
            songDurationSeconds: Double(song.duration) / 1000.0,
            bitrateLabel: currentResponse?.bitrateTitle
        )
        current = np
        for c in continuations.values { c.yield(np) }
        prefetchUpcomingSongArt()
    }

    // Warm the album-art cache for the next two songs so the popover never
    // shows a blank tile during transitions. Matches the song-file prefetch
    // depth (queue[1] + queue[2]) so art lands at the same cadence audio does.
    private func prefetchUpcomingSongArt() {
        for offset in 1...2 {
            guard queue.count > offset else { return }
            let cover = queue[offset].coverLarge ?? queue[offset].coverMedium
            if let cover, !cover.isEmpty {
                prefetchArt(cover)
            }
        }
    }

    private func fireSongStartTelemetry(song: GaplessSong, channelId: Int) {
        guard song.updateHistory else { return }
        let api = self.api
        let songId = song.songId
        let event = String(song.eventId)
        let audioType = song.type
        let sliceNum = String(song.sliceNum)
        Task.detached {
            try? await api.updateHistory(
                songId: songId, chan: channelId, event: event, audioType: audioType,
                sliceNum: sliceNum, playPositionMillis: 0, playtimeSecs: 0,
                pauseFlag: false
            )
        }
    }

    private func describeSong(_ s: GaplessSong) -> String {
        "event=\(s.eventId) type=\(s.type) cue=\(s.cue)ms duration=\(s.duration)ms slice=\(s.sliceNum) songId=\(s.songId) \(s.artist) — \(s.title) url=\(s.gaplessUrl)"
    }

    private func describeQueue(songs: [GaplessSong]) -> String {
        let preview = songs.prefix(5).enumerated().map { i, s in
            "  [\(i)] event=\(s.eventId) cue=\(s.cue)ms duration=\(s.duration)ms type=\(s.type) \(s.artist) — \(s.title)"
        }.joined(separator: "\n")
        let more = songs.count > 5 ? "\n  … (+\(songs.count - 5) more)" : ""
        return "queue (count=\(songs.count)):\n\(preview)\(more)"
    }

    private func kickRefetch() {
        guard refetchTask == nil, let channelId = currentChannelId else { return }
        let headEvent = queue.first?.eventId ?? 0
        let tailEvent = queue.last?.eventId ?? 0
        refetchTask = Task { [weak self] in
            guard let self else { return }
            await self.runRefetch(channelId: channelId, headEvent: headEvent, tailEvent: tailEvent)
        }
    }

    private func kickSequentialDownload() {
        downloaderTask?.cancel()
        let snapshot = queue
        let cache = songFileCache
        downloaderTask = Task {
            // Cap at 2 ahead: queue[1] (typically already on disk from play()'s sync resolve,
            // fast-deduped via fs-exists) and queue[2] (the actual prefetch target).
            // Anything further is downloaded later as the queue head advances and this kicks again.
            for song in snapshot.dropFirst().prefix(2) {
                if Task.isCancelled { return }
                _ = await cache.localFile(for: song)
            }
        }
    }

    private func runRefetch(channelId: Int, headEvent: Int, tailEvent: Int) async {
        let bitrate = await bitrateProvider()
        let response: GaplessResponse
        do {
            response = try await api.gapless(channel: channelId, bitrate: bitrate, numSongs: 20)
        } catch {
            logger.warn("kickRefetch failed: \(error)")
            self.refetchTask = nil
            return
        }
        // Race-guard: discard if channel changed or queue head/tail moved during await.
        guard self.currentChannelId == channelId,
              self.queue.first?.eventId == headEvent,
              self.queue.last?.eventId == tailEvent else {
            logger.debug("kickRefetch result discarded: channel/head/tail moved during fetch")
            self.refetchTask = nil
            return
        }
        let newSongs = response.songs.filter { $0.eventId > tailEvent }
        let hadShortQueue = self.queue.count < 2
        self.queue = self.queue + newSongs
        self.currentResponse = response
        if hadShortQueue, self.queue.count >= 2 {
            let next = self.queue[1]
            let nextUrl = await songFileCache.localFile(for: next)
                ?? URL(string: next.gaplessUrl)
            if let nextUrl, self.queue.count >= 2, self.queue[1].eventId == next.eventId,
               self.queueNextEventId != next.eventId {
                do {
                    try await self.engine.queueNext(url: nextUrl, startSeconds: nil)
                    self.queueNextEventId = next.eventId
                } catch {
                    logger.warn("runRefetch: queueNext failed: \(error)")
                }
            }
        }
        kickSequentialDownload()
        self.refetchTask = nil
    }

    private func unregister(id: UUID) { continuations.removeValue(forKey: id) }
    private func unregisterPosition(id: UUID) { positionContinuations.removeValue(forKey: id) }
    private func unregisterState(id: UUID) { stateContinuations.removeValue(forKey: id) }
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

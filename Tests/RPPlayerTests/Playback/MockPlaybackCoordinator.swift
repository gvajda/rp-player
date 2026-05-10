import Foundation
@testable import RPPlayer

actor MockPlaybackCoordinator: PlaybackCoordinator {
    enum Call: Sendable, Equatable {
        case play(channelId: Int)
        case pause
        case resume
        case stop
        case skipForward
        case changeChannel(to: Int)
        case applyBitrateChange
        case shutdown
    }

    private(set) var calls: [Call] = []
    private var current: NowPlaying?
    private var continuations: [UUID: AsyncStream<NowPlaying>.Continuation] = [:]
    private var positionContinuations: [UUID: AsyncStream<Double>.Continuation] = [:]
    private var stateContinuations: [UUID: AsyncStream<PlaybackState>.Continuation] = [:]
    private var lastPosition: Double = 0
    private var lastState: PlaybackState = .stopped
    private var nextError: Error?
    private var holdChangeChannelEnabled: Bool = false
    private var changeChannelHolds: [CheckedContinuation<Void, Never>] = []
    private(set) var errorsContinuation: AsyncStream<String>.Continuation!
    var errors: AsyncStream<String>

    init() {
        var cont: AsyncStream<String>.Continuation!
        errors = AsyncStream { cont = $0 }
        errorsContinuation = cont
    }

    func fireState(_ state: PlaybackState) {
        lastState = state
        for c in stateContinuations.values { c.yield(state) }
    }

    func setNextError(_ error: Error) { nextError = error }
    func setNowPlaying(_ value: NowPlaying?) {
        current = value
        if let value = value {
            for c in continuations.values { c.yield(value) }
        }
    }
    func firePosition(_ seconds: Double) {
        lastPosition = seconds
        for c in positionContinuations.values { c.yield(seconds) }
    }
    func recordedCalls() -> [Call] { calls }

    var nowPlaying: NowPlaying? { current }

    var nowPlayingUpdates: AsyncStream<NowPlaying> {
        let id = UUID()
        return AsyncStream { continuation in
            self.continuations[id] = continuation
            if let current = self.current { continuation.yield(current) }
            continuation.onTermination = { [weak self] _ in
                Task { [weak self] in await self?.unregister(id: id) }
            }
        }
    }

    var positionUpdates: AsyncStream<Double> {
        let id = UUID()
        return AsyncStream { continuation in
            self.positionContinuations[id] = continuation
            continuation.yield(self.lastPosition)
            continuation.onTermination = { [weak self] _ in
                Task { [weak self] in await self?.unregisterPosition(id: id) }
            }
        }
    }

    var stateUpdates: AsyncStream<PlaybackState> {
        let id = UUID()
        return AsyncStream { continuation in
            self.stateContinuations[id] = continuation
            continuation.yield(self.lastState)
            continuation.onTermination = { [weak self] _ in
                Task { [weak self] in await self?.unregisterState(id: id) }
            }
        }
    }

    var currentPlaybackState: PlaybackState { lastState }

    private func unregister(id: UUID) { continuations.removeValue(forKey: id) }
    private func unregisterPosition(id: UUID) { positionContinuations.removeValue(forKey: id) }
    private func unregisterState(id: UUID) { stateContinuations.removeValue(forKey: id) }

    private func recordOrThrow(_ call: Call) throws {
        if let err = nextError {
            nextError = nil
            throw err
        }
        calls.append(call)
    }

    func play(channelId: Int) async throws { try recordOrThrow(.play(channelId: channelId)) }
    func pause() async throws { try recordOrThrow(.pause) }
    func resume() async throws { try recordOrThrow(.resume) }
    func stop() async throws { try recordOrThrow(.stop) }
    func skipForward() async throws { try recordOrThrow(.skipForward) }
    func changeChannel(to channelId: Int) async throws {
        try recordOrThrow(.changeChannel(to: channelId))
        if holdChangeChannelEnabled {
            await withCheckedContinuation { changeChannelHolds.append($0) }
        }
    }

    func setHoldOnChangeChannel(_ enabled: Bool) {
        holdChangeChannelEnabled = enabled
    }

    func releaseChangeChannelHolds() {
        let pending = changeChannelHolds
        changeChannelHolds.removeAll()
        pending.forEach { $0.resume() }
    }
    func applyBitrateChange() async { calls.append(.applyBitrateChange) }
    func shutdown() async {
        calls.append(.shutdown)
        for c in continuations.values { c.finish() }
        continuations.removeAll()
        for c in positionContinuations.values { c.finish() }
        positionContinuations.removeAll()
        for c in stateContinuations.values { c.finish() }
        stateContinuations.removeAll()
        errorsContinuation.finish()
    }
}

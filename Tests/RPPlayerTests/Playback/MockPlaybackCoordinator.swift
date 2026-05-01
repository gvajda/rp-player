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
        case setBitrate(Int)
        case shutdown
    }

    private(set) var calls: [Call] = []
    private var current: NowPlaying?
    private var continuations: [UUID: AsyncStream<NowPlaying>.Continuation] = [:]
    private var nextError: Error?

    func setNextError(_ error: Error) { nextError = error }
    func setNowPlaying(_ value: NowPlaying?) {
        current = value
        if let value = value {
            for c in continuations.values { c.yield(value) }
        }
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

    private func unregister(id: UUID) { continuations.removeValue(forKey: id) }

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
    }
    func setBitrate(_ newBitrate: Int) {
        calls.append(.setBitrate(newBitrate))
    }
    func shutdown() async {
        calls.append(.shutdown)
        for c in continuations.values { c.finish() }
        continuations.removeAll()
    }
}

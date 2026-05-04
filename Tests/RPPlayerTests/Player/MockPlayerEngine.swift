import Foundation
@testable import RPPlayer

actor MockPlayerEngine: PlayerEngine {
    enum Call: Sendable, Equatable {
        case play(url: URL, startSeconds: Double?)
        case pause
        case resume
        case stop
        case seek(seconds: Double)
        case setOutputDevice(uid: String?)
        case setForceMaxVolume(enabled: Bool)
        case setApplyReplayGain(enabled: Bool)
        case setMute(muted: Bool)
        case shutdown
    }

    private var calls: [Call] = []
    private var continuations: [UUID: AsyncStream<PlayerEvent>.Continuation] = [:]
    private var nextError: Error?

    func recordedCalls() -> [Call] { calls }

    func setNextError(_ error: Error) { nextError = error }

    func fire(_ event: PlayerEvent) {
        for c in continuations.values { c.yield(event) }
    }

    var events: AsyncStream<PlayerEvent> {
        let id = UUID()
        return AsyncStream { continuation in
            self.continuations[id] = continuation
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

    func play(url: URL, startSeconds: Double?) async throws {
        try recordOrThrow(.play(url: url, startSeconds: startSeconds))
    }
    func pause() async throws           { try recordOrThrow(.pause) }
    func resume() async throws          { try recordOrThrow(.resume) }
    func stop() async throws            { try recordOrThrow(.stop) }
    func seek(to seconds: Double) async throws { try recordOrThrow(.seek(seconds: seconds)) }
    func setOutputDevice(uid: String?) async throws {
        try recordOrThrow(.setOutputDevice(uid: uid))
    }
    func setForceMaxVolume(_ enabled: Bool) async throws {
        try recordOrThrow(.setForceMaxVolume(enabled: enabled))
    }
    func setApplyReplayGain(_ enabled: Bool) async throws {
        try recordOrThrow(.setApplyReplayGain(enabled: enabled))
    }
    func setMute(_ muted: Bool) async throws {
        try recordOrThrow(.setMute(muted: muted))
    }
    func shutdown() async {
        calls.append(.shutdown)
        for c in continuations.values { c.finish() }
        continuations.removeAll()
    }
}

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
        case queueNext(url: URL, startSeconds: Double?)
        case advanceToQueued
        case clearPlaylist
        case shutdown
    }

    private var calls: [Call] = []
    private var continuations: [UUID: AsyncStream<PlayerEvent>.Continuation] = [:]
    private var nextError: Error?
    private var simulatedCurrentPath: String?

    func recordedCalls() -> [Call] { calls }

    /// Set the URL string that `currentPath()` will return. Tests fire `.fileStarted` after setting this so the coordinator's resync logic finds the right queue index.
    func setSimulatedCurrentPath(_ url: URL?) { simulatedCurrentPath = url?.absoluteString }

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
        simulatedCurrentPath = url.absoluteString
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
    func queueNext(url: URL, startSeconds: Double?) async throws {
        try recordOrThrow(.queueNext(url: url, startSeconds: startSeconds))
    }
    func advanceToQueued() async throws {
        try recordOrThrow(.advanceToQueued)
    }
    func clearPlaylist() async throws {
        try recordOrThrow(.clearPlaylist)
    }
    func currentPath() async -> String? {
        simulatedCurrentPath
    }
    func shutdown() async {
        calls.append(.shutdown)
        for c in continuations.values { c.finish() }
        continuations.removeAll()
    }
}

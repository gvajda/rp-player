import Foundation

public protocol PlayerEngine: Sendable {
    var events: AsyncStream<PlayerEvent> { get async }

    func play(url: URL, startSeconds: Double?) async throws
    func pause() async throws
    func resume() async throws
    func stop() async throws
    func seek(to seconds: Double) async throws
    func setOutputDevice(uid: String?) async throws
    func setForceMaxVolume(_ enabled: Bool) async throws
    func setApplyReplayGain(_ enabled: Bool) async throws
    func setAudioFilterChain(_ chain: String?) async throws
    func setMute(_ muted: Bool) async throws
    func queueNext(url: URL, startSeconds: Double?) async throws
    func advanceToQueued() async throws
    func clearPlaylist() async throws
    /// URL string of the currently-loaded file (mpv `path` property), or nil if no file is loaded.
    func currentPath() async -> String?
    func shutdown() async
    func muteImmediately()
}

public extension PlayerEngine {
    func play(url: URL) async throws {
        try await play(url: url, startSeconds: nil)
    }
    func muteImmediately() {}
}

public enum PlayerEvent: Sendable, Equatable {
    case positionUpdate(seconds: Double)
    case fileLoaded
    case fileStarted
    case fileEnded(reason: PlayerEndReason)
    case error(message: String)
    case outputDeviceChanged(uid: String?)
    case audioOutputStartFailed
    case shutdown
}

public enum PlayerEndReason: Sendable, Equatable {
    case eof
    case stopped
    case quit
    case error(code: Int)
    case redirect
    case unknown(rawValue: UInt32)
}

public enum PlayerEngineError: Error, Sendable, Equatable {
    case createFailed
    case initializeFailed(code: Int, message: String)
    case setOptionFailed(name: String, code: Int, message: String)
    case commandFailed(name: String, code: Int, message: String)
    case alreadyShutdown
}

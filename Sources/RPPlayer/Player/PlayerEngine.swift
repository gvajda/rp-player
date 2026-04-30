import Foundation

public protocol PlayerEngine: Sendable {
    var events: AsyncStream<PlayerEvent> { get async }

    func play(url: URL) async throws
    func pause() async throws
    func resume() async throws
    func stop() async throws
    func seek(to seconds: Double) async throws
    func setHogMode(_ enabled: Bool) async throws
    func setOutputDevice(uid: String?) async throws
    func shutdown() async
}

public enum PlayerEvent: Sendable, Equatable {
    case positionUpdate(seconds: Double)
    case fileLoaded
    case fileEnded(reason: PlayerEndReason)
    case error(message: String)
    case hogModeChanged(enabled: Bool)
    case outputDeviceChanged(uid: String?)
    case streamFormatChanged(StreamFormat)
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

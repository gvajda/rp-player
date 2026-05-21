import Foundation
@testable import RPPlayer

final class RecordingLogger: Logging, @unchecked Sendable {
    private let lock = NSLock()
    private var lines: [String] = []

    func entries() -> [String] {
        lock.lock(); defer { lock.unlock() }
        return lines
    }

    private func append(_ level: String, _ message: String) {
        lock.lock(); defer { lock.unlock() }
        lines.append("[\(level)] \(message)")
    }

    func debug(_ message: @autoclosure () -> String) { append("DEBUG", message()) }
    func info(_ message: @autoclosure () -> String)  { append("INFO",  message()) }
    func warn(_ message: @autoclosure () -> String)  { append("WARN",  message()) }
    func error(_ message: @autoclosure () -> String) { append("ERROR", message()) }
}

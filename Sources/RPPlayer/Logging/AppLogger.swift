import Foundation
import os

public struct AppLogger: Sendable {
    public enum Level: String, Codable, Sendable, Comparable {
        case debug, info, warn, error

        private var rank: Int {
            switch self {
            case .debug: return 0
            case .info:  return 1
            case .warn:  return 2
            case .error: return 3
            }
        }

        public static func < (lhs: Level, rhs: Level) -> Bool { lhs.rank < rhs.rank }
    }

    public static let subsystem = "com.gvajda.RPPlayer"

    private let osLogger: os.Logger
    private let sink: RotatingFileSink?
    private let category: String
    private let minimumLevel: Level

    public init(category: String, sink: RotatingFileSink? = nil, minimumLevel: Level = .info) {
        self.osLogger = os.Logger(subsystem: Self.subsystem, category: category)
        self.sink = sink
        self.category = category
        self.minimumLevel = minimumLevel
    }

    public func debug(_ message: @autoclosure () -> String) { emit(.debug, message) }
    public func info(_ message: @autoclosure () -> String)  { emit(.info,  message) }
    public func warn(_ message: @autoclosure () -> String)  { emit(.warn,  message) }
    public func error(_ message: @autoclosure () -> String) { emit(.error, message) }

    private func emit(_ level: Level, _ message: () -> String) {
        guard level >= minimumLevel else { return }
        let text = message()
        switch level {
        case .debug: osLogger.debug("\(text, privacy: .public)")
        case .info:  osLogger.info("\(text, privacy: .public)")
        case .warn:  osLogger.warning("\(text, privacy: .public)")
        case .error: osLogger.error("\(text, privacy: .public)")
        }
        sink?.writeLine("\(Self.timestamp()) [\(level.rawValue.uppercased())] [\(category)] \(text)")
    }

    private nonisolated(unsafe) static let iso8601Formatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    private static func timestamp() -> String {
        iso8601Formatter.string(from: Date())
    }
}

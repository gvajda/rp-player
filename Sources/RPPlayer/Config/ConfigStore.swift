import Foundation

public protocol ConfigStore: Sendable, AnyObject {
    var settings: AppSettings { get async }
    var changes: AsyncStream<AppSettings> { get }
    func update(_ mutate: @Sendable (inout AppSettings) -> Void) async throws
}

public actor JSONConfigStore: ConfigStore {
    public let url: URL
    private var current: AppSettings
    private var continuations: [UUID: AsyncStream<AppSettings>.Continuation] = [:]

    public init(url: URL) throws {
        self.url = url
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        if let data = try? Data(contentsOf: url),
           let loaded = try? JSONDecoder().decode(AppSettings.self, from: data) {
            self.current = loaded
        } else {
            self.current = .default
            try? Self.write(.default, to: url)
        }
    }

    public var settings: AppSettings { current }

    public nonisolated var changes: AsyncStream<AppSettings> {
        AsyncStream { continuation in
            let id = UUID()
            Task { await self.register(id: id, continuation: continuation) }
            continuation.onTermination = { _ in
                Task { await self.unregister(id: id) }
            }
        }
    }

    public func update(_ mutate: @Sendable (inout AppSettings) -> Void) async throws {
        var copy = current
        mutate(&copy)
        guard copy != current else { return }
        try Self.write(copy, to: url)
        current = copy
        for c in continuations.values {
            c.yield(copy)
        }
    }

    private func register(id: UUID, continuation: AsyncStream<AppSettings>.Continuation) {
        continuations[id] = continuation
        continuation.yield(current)
    }

    private func unregister(id: UUID) {
        continuations.removeValue(forKey: id)
    }

    private static func write(_ settings: AppSettings, to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(settings)
        try data.write(to: url, options: [.atomic])
    }
}

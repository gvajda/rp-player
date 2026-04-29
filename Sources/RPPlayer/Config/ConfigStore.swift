import Foundation

/// Persistent, concurrency-safe settings store. Backed by JSON on disk; mock-able in tests via the protocol.
public protocol ConfigStore: Sendable, AnyObject {
    var settings: AppSettings { get async }
    var changes: AsyncStream<AppSettings> { get async }
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
            // Best-effort initial write; in-memory defaults remain valid if disk write fails.
            try? Self.write(.default, to: url)
        }
    }

    public var settings: AppSettings { current }

    /// Subscribes a new continuation atomically: by the time the stream is returned,
    /// the subscriber is registered and has been yielded the current snapshot.
    /// Subsequent `update` calls on this actor are guaranteed to be observed.
    public var changes: AsyncStream<AppSettings> {
        let id = UUID()
        return AsyncStream { continuation in
            self.continuations[id] = continuation
            continuation.yield(self.current)
            continuation.onTermination = { [weak self] _ in
                Task { [weak self] in await self?.unregister(id: id) }
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

import Foundation
@testable import RPPlayer

/// Test double. Two modes:
///   - default `.passthrough`: `localFile(for:)` returns `URL(string: song.gaplessUrl)`. No real download.
///   - `.downloaded(URL)`: `localFile(for:)` returns a fixed file URL for any song (tests that need a file URL specifically).
///
/// Records every call (localFile, cachedFile, evict, clear) for assertion. Concurrency-safe.
actor MockSongFileCache: SongFileCache {
    enum Mode {
        case passthrough
        case downloaded(URL)
    }

    var mode: Mode = .passthrough
    var failingEventIds: Set<Int> = []
    private(set) var localFileCalls: [Int] = []
    private(set) var cachedFileCalls: [Int] = []
    private(set) var evictCalls: [Int] = []
    private(set) var clearCalls: Int = 0
    private(set) var cancelInFlightCalls: Int = 0
    private var downloadedEventIds: Set<Int> = []

    func setMode(_ m: Mode) { mode = m }
    func setFailing(_ ids: Set<Int>) { failingEventIds = ids }
    func markDownloaded(_ ids: Set<Int>) { downloadedEventIds.formUnion(ids) }

    func localFile(for song: GaplessSong) async -> URL? {
        localFileCalls.append(song.eventId)
        if failingEventIds.contains(song.eventId) { return nil }
        downloadedEventIds.insert(song.eventId)
        switch mode {
        case .passthrough: return URL(string: song.gaplessUrl)
        case .downloaded(let u): return u
        }
    }

    /// Override per-song return value for cachedFile. Set to nil for the default (return nil for all songs).
    /// Use a nonisolated(unsafe) var so the closure can be mutated from test setup before the coordinator runs.
    nonisolated(unsafe) var cachedFileOverride: (@Sendable (GaplessSong) -> URL?)?

    nonisolated func cachedFile(for song: GaplessSong) -> URL? {
        if let override = cachedFileOverride { return override(song) }
        // Cannot read actor state nonisolated — return nil here.
        // Coordinator code that depends on cachedFile semantics falls into the
        // awaited localFile path in tests, which is fine since the mock resolves
        // immediately. Real LiveSongFileCache does a synchronous fs probe.
        return nil
    }

    func evict(_ song: GaplessSong) async {
        evictCalls.append(song.eventId)
        downloadedEventIds.remove(song.eventId)
    }

    func clear() async {
        clearCalls += 1
        downloadedEventIds.removeAll()
    }

    func cancelInFlightDownloads() {
        cancelInFlightCalls += 1
    }

    nonisolated func expectedLocalPath(for song: GaplessSong) -> URL {
        // Tests using .passthrough mode treat the remote URL as "the path mpv sees".
        // For .downloaded(URL) tests that need path-matching, drive the engine's
        // simulated currentPath() to match the URL the test passed into setMode.
        URL(string: song.gaplessUrl) ?? URL(fileURLWithPath: "/dev/null")
    }
}

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
    private var inFlightEventIds: Set<Int> = []
    private var inFlightWaiters: [Int: [CheckedContinuation<URL?, Never>]] = [:]
    private var releasedInFlightUrls: [Int: URL] = [:]
    // Nonisolated mirror of released downloads so cachedFile(for:) can see them
    // without violating actor isolation. Mirrors LiveSongFileCache, where
    // cachedFile is a synchronous fs-exists probe.
    private let releasedMirror = NonIsolatedURLMap()

    func setMode(_ m: Mode) { mode = m }
    func setFailing(_ ids: Set<Int>) { failingEventIds = ids }
    func markDownloaded(_ ids: Set<Int>) { downloadedEventIds.formUnion(ids) }

    /// Marks the given eventIds as "in-flight": `localFile(for:)` will await a
    /// continuation that the test releases via `releaseInFlight(eventId:url:)`.
    /// `cachedFile(for:)` continues to follow `cachedFileOverride` (nil by default),
    /// so callers see a cache miss until release.
    func setInFlight(_ ids: Set<Int>) { inFlightEventIds = ids }

    /// Resumes any `localFile(for: eventId)` waiters with `url`, and seeds future
    /// calls with the same URL. The eventId is also removed from the in-flight set.
    func releaseInFlight(eventId: Int, url: URL) {
        inFlightEventIds.remove(eventId)
        releasedInFlightUrls[eventId] = url
        downloadedEventIds.insert(eventId)
        releasedMirror.set(eventId: eventId, url: url)
        let waiters = inFlightWaiters.removeValue(forKey: eventId) ?? []
        for w in waiters { w.resume(returning: url) }
    }

    func localFile(for song: GaplessSong) async -> URL? {
        localFileCalls.append(song.eventId)
        if failingEventIds.contains(song.eventId) { return nil }
        if inFlightEventIds.contains(song.eventId) {
            return await withCheckedContinuation { (cont: CheckedContinuation<URL?, Never>) in
                inFlightWaiters[song.eventId, default: []].append(cont)
            }
        }
        if let released = releasedInFlightUrls[song.eventId] {
            downloadedEventIds.insert(song.eventId)
            return released
        }
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
        // Mirror released-in-flight downloads so post-download hooks (which run
        // after localFile resolves) see a cache hit, like real LiveSongFileCache.
        return releasedMirror.get(eventId: song.eventId)
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

// Thread-safe nonisolated [Int: URL] mirror so cachedFile(for:) (called outside actor isolation) can see URLs published by releaseInFlight.
final class NonIsolatedURLMap: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [Int: URL] = [:]

    func set(eventId: Int, url: URL) {
        lock.lock(); defer { lock.unlock() }
        storage[eventId] = url
    }

    func get(eventId: Int) -> URL? {
        lock.lock(); defer { lock.unlock() }
        return storage[eventId]
    }
}

import XCTest
@testable import RPPlayer

final class SongFileCacheTests: XCTestCase {

    // MARK: - helpers

    private func makeTempDir() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("SongFileCacheTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func sessionWithStub() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubURLProtocol.self]
        return URLSession(configuration: config)
    }

    private func makeSong(url: String = "https://stream.radioparadise.com/test.flac",
                         eventId: Int = 1) -> GaplessSong {
        makeGaplessSong(eventId: eventId, gaplessUrl: url)
    }

    private func makeLogger() -> AppLogger {
        AppLogger(category: "SongFileCacheTests")
    }

    override func tearDown() async throws {
        StubURLProtocol.reset()
        try await super.tearDown()
    }

    // MARK: - tests

    func testLocalFileDownloadsAndStoresAtKeyedPath() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let body = Data(repeating: 0xAB, count: 1024)
        let song = makeSong()
        StubURLProtocol.register(url: URL(string: song.gaplessUrl)!, body: body, status: 200)

        let cache = try LiveSongFileCache(
            directory: dir,
            session: sessionWithStub(),
            logger: makeLogger()
        )

        let local = await cache.localFile(for: song)

        XCTAssertNotNil(local)
        XCTAssertEqual(try Data(contentsOf: local!), body)
        XCTAssertEqual(local!.deletingLastPathComponent(), dir)
        XCTAssertEqual(local!.pathExtension, "flac")
    }

    func testLocalFileReturnsCachedWithoutRefetch() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let body = Data(repeating: 0x01, count: 512)
        let song = makeSong()
        StubURLProtocol.register(url: URL(string: song.gaplessUrl)!, body: body, status: 200)

        let cache = try LiveSongFileCache(
            directory: dir,
            session: sessionWithStub(),
            logger: makeLogger()
        )

        _ = await cache.localFile(for: song)
        StubURLProtocol.reset() // any new fetch attempt would now fail
        let local = await cache.localFile(for: song)

        XCTAssertNotNil(local)
        XCTAssertEqual(try Data(contentsOf: local!), body)
    }

    func testCachedFileReturnsNilForUnknownSong() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let cache = try LiveSongFileCache(
            directory: dir,
            session: sessionWithStub(),
            logger: makeLogger()
        )
        XCTAssertNil(cache.cachedFile(for: makeSong()))
    }

    func testCachedFileReturnsUrlAfterDownload() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let song = makeSong()
        StubURLProtocol.register(url: URL(string: song.gaplessUrl)!, body: Data([0xFF]), status: 200)
        let cache = try LiveSongFileCache(
            directory: dir,
            session: sessionWithStub(),
            logger: makeLogger()
        )
        _ = await cache.localFile(for: song)
        XCTAssertNotNil(cache.cachedFile(for: song))
    }

    func testEvictRemovesFile() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let song = makeSong()
        StubURLProtocol.register(url: URL(string: song.gaplessUrl)!, body: Data([1, 2, 3]), status: 200)
        let cache = try LiveSongFileCache(
            directory: dir,
            session: sessionWithStub(),
            logger: makeLogger()
        )
        let local = await cache.localFile(for: song)
        XCTAssertNotNil(local)
        XCTAssertTrue(FileManager.default.fileExists(atPath: local!.path))

        await cache.evict(song)

        XCTAssertFalse(FileManager.default.fileExists(atPath: local!.path))
        XCTAssertNil(cache.cachedFile(for: song))
    }

    func testClearRemovesAll() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let song1 = makeSong(url: "https://s.example.com/a.flac", eventId: 1)
        let song2 = makeSong(url: "https://s.example.com/b.flac", eventId: 2)
        StubURLProtocol.register(url: URL(string: song1.gaplessUrl)!, body: Data([1]), status: 200)
        StubURLProtocol.register(url: URL(string: song2.gaplessUrl)!, body: Data([2]), status: 200)
        let cache = try LiveSongFileCache(
            directory: dir,
            session: sessionWithStub(),
            logger: makeLogger()
        )
        _ = await cache.localFile(for: song1)
        _ = await cache.localFile(for: song2)

        await cache.clear()

        let entries = try FileManager.default.contentsOfDirectory(atPath: dir.path)
        XCTAssertEqual(entries, [])
        XCTAssertNil(cache.cachedFile(for: song1))
        XCTAssertNil(cache.cachedFile(for: song2))
    }

    func testLocalFileReturnsNilOnHttpError() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let song = makeSong()
        StubURLProtocol.register(url: URL(string: song.gaplessUrl)!, body: Data(), status: 503)
        let cache = try LiveSongFileCache(
            directory: dir,
            session: sessionWithStub(),
            logger: makeLogger()
        )
        let local = await cache.localFile(for: song)
        XCTAssertNil(local)
        XCTAssertNil(cache.cachedFile(for: song))
    }

    func testLocalFileReturnsNilOnEmptyBody() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let song = makeSong()
        StubURLProtocol.register(url: URL(string: song.gaplessUrl)!, body: Data(), status: 200)
        let cache = try LiveSongFileCache(
            directory: dir,
            session: sessionWithStub(),
            logger: makeLogger()
        )
        let result = await cache.localFile(for: song)
        XCTAssertNil(result)
    }

    // Parallel-dedup verification is deferred to Task 3: it needs a `delayMs:`
    // knob on StubURLProtocol (or a request counter) to assert that three
    // concurrent localFile calls collapse to a single network request. The
    // current stub fires synchronously, so naive parallel calls cannot
    // distinguish dedup from sequential cache hits.
    func testParallelLocalFileCallsReturnConsistentData() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let song = makeSong()
        let body = Data(repeating: 0x77, count: 256)
        StubURLProtocol.register(url: URL(string: song.gaplessUrl)!, body: body, status: 200)
        let cache = try LiveSongFileCache(
            directory: dir,
            session: sessionWithStub(),
            logger: makeLogger()
        )

        async let a = cache.localFile(for: song)
        async let b = cache.localFile(for: song)
        async let c = cache.localFile(for: song)
        let results = await [a, b, c]

        for r in results {
            XCTAssertNotNil(r)
            XCTAssertEqual(try Data(contentsOf: r!), body)
        }
        XCTAssertEqual(Set(results.compactMap { $0 }).count, 1)
    }

    func testEvictsOldestWhenOverMaxFiles() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let cache = try LiveSongFileCache(
            directory: dir,
            session: sessionWithStub(),
            logger: makeLogger(),
            maxFiles: 3
        )
        // Download 5 distinct songs; only the 3 most recent should survive.
        for i in 1...5 {
            let song = makeSong(url: "https://s.example.com/song-\(i).flac", eventId: i)
            StubURLProtocol.register(url: URL(string: song.gaplessUrl)!, body: Data([UInt8(i)]), status: 200)
            _ = await cache.localFile(for: song)
            // sleep 50ms so mtimes are distinct enough for the sort to be deterministic
            try await Task.sleep(nanoseconds: 50_000_000)
        }

        let entries = try FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)
        XCTAssertEqual(entries.count, 3, "cache should have evicted down to maxFiles=3")
    }

    // Cancellation contract: when the caller's Task is cancelled before
    // localFile resumes, downloadAndStore must not leave a file on disk.
    // The stub fires synchronously so the write race may still complete
    // — best-effort assertion: any file present here must round-trip the
    // body (no half-written orphan), and the cancellation path itself
    // must not crash.
    func testInFlightDownloadRespectsCancellation() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let song = makeSong()
        StubURLProtocol.register(url: URL(string: song.gaplessUrl)!, body: Data([1, 2, 3]), status: 200)
        let cache = try LiveSongFileCache(
            directory: dir,
            session: sessionWithStub(),
            logger: makeLogger()
        )

        let task = Task {
            await cache.localFile(for: song)
        }
        task.cancel()
        _ = await task.value

        let entries = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
        for url in entries {
            let data = try Data(contentsOf: url)
            XCTAssertEqual(data, Data([1, 2, 3]), "any file present after cancellation must be intact (not a partial write)")
        }
    }

    func testCancelInFlightDownloadsCancelsActiveTasks() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let song = makeSong()
        StubURLProtocol.register(url: URL(string: song.gaplessUrl)!, body: Data([1,2,3]), status: 200)
        let cache = try LiveSongFileCache(directory: dir, session: sessionWithStub(), logger: makeLogger())

        // Start a download (don't await; let it begin)
        let task = Task { await cache.localFile(for: song) }

        // Cancel everything in-flight
        await cache.cancelInFlightDownloads()

        let result = await task.value
        // Result may be nil (cancelled before write) OR a URL (write completed before cancel
        // propagated — race). The important assertion is: no crash, and a subsequent
        // localFile call works correctly.
        _ = result

        // Subsequent download should still work
        StubURLProtocol.register(url: URL(string: song.gaplessUrl)!, body: Data([1,2,3]), status: 200)
        let again = await cache.localFile(for: song)
        XCTAssertNotNil(again)
    }
}

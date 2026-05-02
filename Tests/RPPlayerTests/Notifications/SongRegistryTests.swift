import XCTest
@testable import RPPlayer

private func makeSong(id: String, title: String = "T") -> PlayListSong {
    PlayListSong(
        songId: id, artist: "A", title: title, album: "Al", duration: 1000,
        event: nil, schedTime: nil, chan: nil, year: nil, asin: nil,
        rating: nil, userRating: nil, cover: nil, elapsed: nil, slideshow: nil,
        type: nil, sliceNum: nil
    )
}

final class SongRegistryTests: XCTestCase {
    func testRecordAndLookupReturnsTheRecordedSong() async {
        let registry = SongRegistry(capacity: 10)
        await registry.record(makeSong(id: "1", title: "First"))
        let result = await registry.lookup(songId: "1")
        XCTAssertEqual(result?.title, "First")
    }

    func testLookupReturnsNilForUnknownId() async {
        let registry = SongRegistry(capacity: 10)
        let result = await registry.lookup(songId: "missing")
        XCTAssertNil(result)
    }

    func testCapacityEvictsOldestFirst() async {
        let registry = SongRegistry(capacity: 3)
        await registry.record(makeSong(id: "1"))
        await registry.record(makeSong(id: "2"))
        await registry.record(makeSong(id: "3"))
        await registry.record(makeSong(id: "4"))
        let evicted = await registry.lookup(songId: "1")
        let kept = await registry.lookup(songId: "4")
        XCTAssertNil(evicted)
        XCTAssertNotNil(kept)
    }

    func testDuplicateRecordMovesToFrontAndReplaces() async {
        let registry = SongRegistry(capacity: 3)
        await registry.record(makeSong(id: "1", title: "First"))
        await registry.record(makeSong(id: "2"))
        await registry.record(makeSong(id: "3"))
        // Re-record id=1 with new metadata.
        await registry.record(makeSong(id: "1", title: "First (updated)"))
        // Now record id=4 — id=2 (oldest after the move) should be evicted, NOT id=1.
        await registry.record(makeSong(id: "4"))
        let updated = await registry.lookup(songId: "1")
        let evicted = await registry.lookup(songId: "2")
        XCTAssertEqual(updated?.title, "First (updated)")
        XCTAssertNil(evicted)
    }
}

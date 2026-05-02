import XCTest
@testable import RPPlayer

final class BlockSongsTests: XCTestCase {
    private func song(id: String, duration: Int, elapsed: Int) -> PlayListSong {
        PlayListSong(
            songId: id, artist: "A", title: id, album: "Al", duration: duration,
            event: nil, schedTime: nil, chan: nil, year: nil, asin: nil,
            rating: nil, userRating: nil, cover: nil, elapsed: elapsed, slideshow: nil,
            type: nil, sliceNum: nil
        )
    }

    private func block(songs: [(String, Int)], cue: Int = 0) -> GetBlock {
        var dict: [String: PlayListSong] = [:]
        var elapsed = 0
        for (idx, pair) in songs.enumerated() {
            dict[String(idx)] = song(id: pair.0, duration: pair.1, elapsed: elapsed)
            elapsed += pair.1
        }
        return GetBlock(
            url: "https://example.com/x.flac",
            chan: "0", bitrate: nil, cue: cue, expiration: 0,
            length: nil, imageBase: "img/", song: dict,
            channel: nil, event: nil, endEvent: nil, type: nil, ext: nil
        )
    }

    func testOrderedSongsSortsByIntKey() {
        let b = GetBlock(
            url: "u", chan: "0", bitrate: nil, cue: 0, expiration: 0,
            length: nil, imageBase: "",
            song: [
                "2": song(id: "c", duration: 10000, elapsed: 50000),
                "0": song(id: "a", duration: 30000, elapsed: 0),
                "1": song(id: "b", duration: 20000, elapsed: 30000),
            ],
            channel: nil, event: nil, endEvent: nil, type: nil, ext: nil
        )
        let ordered = BlockSongs.orderedSongs(from: b)
        XCTAssertEqual(ordered.map(\.songId), ["a", "b", "c"])
    }

    func testStartsAtSecondsUsesElapsedField() {
        let b = block(songs: [("a", 60_000), ("b", 120_000), ("c", 90_000), ("d", 100_000)])
        let starts = BlockSongs.startsAtSeconds(songs: BlockSongs.orderedSongs(from: b))
        XCTAssertEqual(starts, [0, 60, 180, 270])
    }

    func testStartsAtSecondsForEmptyBlockIsEmpty() {
        let b = block(songs: [])
        let starts = BlockSongs.startsAtSeconds(songs: BlockSongs.orderedSongs(from: b))
        XCTAssertEqual(starts, [])
    }

    func testTotalDurationSecondsReturnsEndOfLastSong() {
        let b = block(songs: [("a", 60_000), ("b", 120_000), ("c", 90_000), ("d", 100_000)])
        let total = BlockSongs.totalDurationSeconds(songs: BlockSongs.orderedSongs(from: b))
        XCTAssertEqual(total, 370.0, accuracy: 0.001)
    }

    func testIndexOfSongWithinFirstSong() {
        let starts: [Double] = [0, 60, 180, 270]
        XCTAssertEqual(BlockSongs.indexOfSong(at: 0.0, in: starts), 0)
        XCTAssertEqual(BlockSongs.indexOfSong(at: 30.0, in: starts), 0)
        XCTAssertEqual(BlockSongs.indexOfSong(at: 59.999, in: starts), 0)
    }

    func testIndexOfSongCrossesBoundary() {
        let starts: [Double] = [0, 60, 180, 270]
        XCTAssertEqual(BlockSongs.indexOfSong(at: 60.0, in: starts), 1)
        XCTAssertEqual(BlockSongs.indexOfSong(at: 100.0, in: starts), 1)
        XCTAssertEqual(BlockSongs.indexOfSong(at: 180.0, in: starts), 2)
        XCTAssertEqual(BlockSongs.indexOfSong(at: 269.999, in: starts), 2)
        XCTAssertEqual(BlockSongs.indexOfSong(at: 270.0, in: starts), 3)
    }

    func testIndexOfSongNegativePositionClampsToZero() {
        let starts: [Double] = [0, 60, 180, 270]
        XCTAssertEqual(BlockSongs.indexOfSong(at: -5.0, in: starts), 0)
    }

    func testIndexOfSongPastEndClampsToLast() {
        let starts: [Double] = [0, 60, 180, 270]
        XCTAssertEqual(BlockSongs.indexOfSong(at: 99999.0, in: starts), 3)
    }
}

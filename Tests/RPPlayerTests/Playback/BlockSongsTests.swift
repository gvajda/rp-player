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

    func testIsStaleReturnsTrueWhenCueZeroAndAllElapsedNonPositive() {
        let songs = [
            song(id: "x", duration: 275_300, elapsed: -1_069_700),
            song(id: "x", duration: 505_000, elapsed: -794_400),
            song(id: "x", duration: 289_400, elapsed: -289_400),
        ]
        XCTAssertTrue(BlockSongs.isStale(songs: songs, cue: 0))
    }

    func testIsStaleReturnsFalseForFreshPromoBlock() {
        // Promo block: single song, cue=0, elapsed=0, type="P". Must NOT be stale.
        let songs = [song(id: "x", duration: 5_000, elapsed: 0)]
        XCTAssertFalse(BlockSongs.isStale(songs: songs, cue: 0))
    }

    func testIsStaleRequiresAtLeastOneStrictlyNegativeElapsed() {
        // All-zero elapsed (degenerate music block at boundary) is NOT stale either.
        let songs = [
            song(id: "x", duration: 60_000, elapsed: 0),
            song(id: "x", duration: 60_000, elapsed: 0),
        ]
        XCTAssertFalse(BlockSongs.isStale(songs: songs, cue: 0))
    }

    func testIsStaleReturnsFalseWhenAnyElapsedPositive() {
        let songs = [
            song(id: "x", duration: 60_000, elapsed: -1_000),
            song(id: "x", duration: 60_000, elapsed: 60_000),
        ]
        XCTAssertFalse(BlockSongs.isStale(songs: songs, cue: 0))
    }

    func testIsStaleReturnsFalseWhenCueWithinFreshBlock() {
        // cue within the block's audio file range; not stale.
        let songs = [
            song(id: "x", duration: 60_000, elapsed: 0),
            song(id: "x", duration: 60_000, elapsed: 60_000),
        ]
        XCTAssertFalse(BlockSongs.isStale(songs: songs, cue: 30_000))
    }

    func testIsStaleReturnsTrueWhenCuePastBlockEnd() {
        // Real-data scenario: server returned a block whose audio file ends at
        // 1806600ms but cue is set to 2417499ms (well past end). Naive playback
        // seeks beyond file length and mpv errors out ~9s later.
        let songs = [
            song(id: "a", duration: 275_300, elapsed: 190_500),
            song(id: "b", duration: 339_400, elapsed: 465_800),
            song(id: "c", duration: 265_200, elapsed: 805_200),
            song(id: "d", duration: 223_100, elapsed: 1_070_400),
            song(id: "e", duration: 165_800, elapsed: 1_293_500),
            song(id: "f", duration: 347_300, elapsed: 1_459_300),
        ]
        XCTAssertTrue(BlockSongs.isStale(songs: songs, cue: 2_417_499))
    }

    func testIsStaleReturnsTrueWhenCueExactlyAtBlockEnd() {
        // cue == totalMs is past the last playable frame; treat as stale.
        let songs = [
            song(id: "x", duration: 60_000, elapsed: 0),
            song(id: "x", duration: 60_000, elapsed: 60_000),
        ]
        XCTAssertTrue(BlockSongs.isStale(songs: songs, cue: 120_000))
    }

    func testIsStaleReturnsFalseForEmptySongs() {
        XCTAssertFalse(BlockSongs.isStale(songs: [], cue: 0))
    }
}

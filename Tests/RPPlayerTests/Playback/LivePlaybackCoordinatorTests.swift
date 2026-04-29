import XCTest
@testable import RPPlayer

final class LivePlaybackCoordinatorTests: XCTestCase {
    fileprivate func makeSong(id: String, duration: Int) -> PlayListSong {
        PlayListSong(
            songId: id, artist: "Artist-\(id)", title: "Title-\(id)", album: "Al", duration: duration,
            event: nil, schedTime: nil, chan: nil, year: nil, asin: nil,
            rating: nil, userRating: nil, cover: nil, elapsed: nil, slideshow: nil
        )
    }

    fileprivate func makeBlock(channel: String = "0", url: String = "https://example.com/0-0.flac",
                                cue: Int = 0,
                                songs: [(String, Int)]) -> GetBlock {
        var dict: [String: PlayListSong] = [:]
        for (idx, pair) in songs.enumerated() {
            dict[String(idx)] = makeSong(id: pair.0, duration: pair.1)
        }
        return GetBlock(
            url: url, chan: channel, bitrate: nil, cue: cue, expiration: 0,
            length: nil, imageBase: "img/", song: dict,
            channel: nil, event: nil, endEvent: nil, type: nil, ext: nil, filename: nil
        )
    }

    fileprivate func silentLogger() -> AppLogger {
        AppLogger(category: "PlaybackCoordinatorTests")
    }

    func testPlayCallsGetBlockAndEnginePlay() async throws {
        let api = MockRpApiClient()
        let block = makeBlock(songs: [("s1", 60_000), ("s2", 120_000), ("s3", 90_000), ("s4", 100_000)])
        await api.setBlockResponses([block])
        let engine = MockPlayerEngine()
        let coordinator = LivePlaybackCoordinator(
            api: api, engine: engine, logger: silentLogger(), bitrate: 4
        )
        try await coordinator.play(channelId: 0)
        let apiCalls = await api.calls
        let engineCalls = await engine.recordedCalls()
        XCTAssertEqual(apiCalls, [.getBlock(channel: 0, bitrate: 4, info: false)])
        XCTAssertEqual(engineCalls, [.play(url: URL(string: "https://example.com/0-0.flac")!)])
    }

    func testPlaySeeksToCueOffsetAfterFileLoad() async throws {
        let api = MockRpApiClient()
        let block = makeBlock(cue: 90_000,
                              songs: [("s1", 60_000), ("s2", 120_000), ("s3", 90_000), ("s4", 100_000)])
        await api.setBlockResponses([block])
        let engine = MockPlayerEngine()
        let coordinator = LivePlaybackCoordinator(
            api: api, engine: engine, logger: silentLogger(), bitrate: 4
        )
        try await coordinator.play(channelId: 0)
        await engine.fire(.fileLoaded)
        try await Task.sleep(nanoseconds: 50_000_000)
        let engineCalls = await engine.recordedCalls()
        XCTAssertEqual(engineCalls, [
            .play(url: URL(string: "https://example.com/0-0.flac")!),
            .seek(seconds: 90.0),
        ])
    }

    func testPlayThrowsWhenBlockHasNoSongs() async throws {
        let api = MockRpApiClient()
        let block = makeBlock(songs: [])
        await api.setBlockResponses([block])
        let engine = MockPlayerEngine()
        let coordinator = LivePlaybackCoordinator(
            api: api, engine: engine, logger: silentLogger(), bitrate: 4
        )
        do {
            try await coordinator.play(channelId: 0)
            XCTFail("expected blockHasNoSongs")
        } catch let error as PlaybackCoordinatorError {
            XCTAssertEqual(error, .blockHasNoSongs)
        }
    }

    func testNowPlayingIsNilBeforePlay() async throws {
        let api = MockRpApiClient()
        let engine = MockPlayerEngine()
        let coordinator = LivePlaybackCoordinator(
            api: api, engine: engine, logger: silentLogger(), bitrate: 4
        )
        let np = await coordinator.nowPlaying
        XCTAssertNil(np)
    }
}

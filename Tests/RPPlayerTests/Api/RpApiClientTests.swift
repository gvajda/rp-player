import XCTest
@testable import RPPlayer

final class RpApiClientTests: XCTestCase {
    private let baseURL = URL(string: "https://api.radioparadise.com/")!

    private func loadFixture(_ name: String) throws -> Data {
        let url = try XCTUnwrap(Bundle.module.url(forResource: "Fixtures/Api/\(name)", withExtension: "json"))
        return try Data(contentsOf: url)
    }

    private func makeClient(playerId: String? = nil) -> LiveRpApiClient {
        LiveRpApiClient(
            baseURL: baseURL,
            session: StubURLProtocol.makeSession(),
            cookieProvider: AnonymousCookieProvider(),
            playerId: playerId,
            logger: AppLogger(category: "RpApiClientTests")
        )
    }

    override func setUp() {
        super.setUp()
        StubURLProtocol.reset()
    }

    override func tearDown() {
        StubURLProtocol.reset()
        super.tearDown()
    }

    func testListChannelsReturnsDecodedArray() async throws {
        let url = baseURL.appendingPathComponent("api/list_chan")
        StubURLProtocol.register(url: url, body: try loadFixture("list_chan"))

        let client = makeClient()
        let channels = try await client.listChannels()
        XCTAssertGreaterThan(channels.count, 0)
    }

    func testInfoBuildsCorrectQueryAndDecodes() async throws {
        var components = URLComponents(url: baseURL.appendingPathComponent("api/info"), resolvingAgainstBaseURL: false)!
        components.queryItems = [URLQueryItem(name: "song_id", value: "20093")]
        StubURLProtocol.register(url: components.url!, body: try loadFixture("info"))

        let client = makeClient()
        let info = try await client.info(songId: 20093)
        XCTAssertFalse(info.artist.isEmpty)
    }

    func testAuthStateAnonymousDecodes() async throws {
        let url = baseURL.appendingPathComponent("api/auth-state")
        StubURLProtocol.register(url: url, body: try loadFixture("auth_state_anonymous"))

        let client = makeClient()
        let auth = try await client.authState()
        // Just verify it decodes; field shape is loose.
        _ = auth
    }

    func testRateBuildsCorrectQueryAndDecodes() async throws {
        var components = URLComponents(url: baseURL.appendingPathComponent("api/rating"), resolvingAgainstBaseURL: false)!
        // Match the client's deterministic alpha-by-name ordering of query items.
        components.queryItems = [
            URLQueryItem(name: "rating", value: "7"),
            URLQueryItem(name: "song_id", value: "12345"),
        ]
        StubURLProtocol.register(url: components.url!, body: try loadFixture("rating_success"))

        let client = makeClient()
        let rating = try await client.rate(songId: 12345, rating: 7)
        XCTAssertEqual(rating.status, "success")
        XCTAssertEqual(rating.userRating, 7)
    }

    func testUpdateHistoryBuildsCorrectURL() async throws {
        var components = URLComponents(url: baseURL.appendingPathComponent("api/update_history"), resolvingAgainstBaseURL: false)!
        components.queryItems = [
            URLQueryItem(name: "chan", value: "0"),
            URLQueryItem(name: "episode_id", value: "0"),
            URLQueryItem(name: "event", value: "2869397"),
            URLQueryItem(name: "event_num", value: "undefined"),
            URLQueryItem(name: "play_position_millis", value: "3194"),
            URLQueryItem(name: "player_id", value: "rp3_test-player"),
            URLQueryItem(name: "playtime_secs", value: "1777746855"),
            URLQueryItem(name: "slice_num", value: "5"),
            URLQueryItem(name: "song_id", value: "20093"),
            URLQueryItem(name: "source", value: "24"),
            URLQueryItem(name: "time_relative", value: "-3"),
            URLQueryItem(name: "type", value: "M"),
        ]
        StubURLProtocol.register(url: components.url!, body: Data())
        let client = makeClient(playerId: "rp3_test-player")
        try await client.updateHistory(
            songId: "20093", chan: 0, event: "2869397", audioType: "M",
            sliceNum: "5", playPositionMillis: 3194, playtimeSecs: 1777746855,
            pauseFlag: false
        )
    }

    func testUpdateHistoryWithPauseFlagAddsParam() async throws {
        var components = URLComponents(url: baseURL.appendingPathComponent("api/update_history"), resolvingAgainstBaseURL: false)!
        components.queryItems = [
            URLQueryItem(name: "chan", value: "0"),
            URLQueryItem(name: "episode_id", value: "0"),
            URLQueryItem(name: "event", value: "2869397"),
            URLQueryItem(name: "event_num", value: "undefined"),
            URLQueryItem(name: "pause", value: "1"),
            URLQueryItem(name: "play_position_millis", value: "21233"),
            URLQueryItem(name: "player_id", value: "rp3_test-player"),
            URLQueryItem(name: "playtime_secs", value: "1777746905"),
            URLQueryItem(name: "slice_num", value: "6"),
            URLQueryItem(name: "song_id", value: "55464"),
            URLQueryItem(name: "source", value: "24"),
            URLQueryItem(name: "time_relative", value: "-21"),
            URLQueryItem(name: "type", value: "M"),
        ]
        StubURLProtocol.register(url: components.url!, body: Data())
        let client = makeClient(playerId: "rp3_test-player")
        try await client.updateHistory(
            songId: "55464", chan: 0, event: "2869397", audioType: "M",
            sliceNum: "6", playPositionMillis: 21233, playtimeSecs: 1777746905,
            pauseFlag: true
        )
    }

    func testUpdatePauseBuildsCorrectURL() async throws {
        var components = URLComponents(url: baseURL.appendingPathComponent("api/update_pause"), resolvingAgainstBaseURL: false)!
        components.queryItems = [
            URLQueryItem(name: "chan", value: "0"),
            URLQueryItem(name: "episode_id", value: "0"),
            URLQueryItem(name: "event", value: "2869397"),
            URLQueryItem(name: "event_num", value: "undefined"),
            URLQueryItem(name: "pause", value: "21233"),
            URLQueryItem(name: "player_id", value: "rp3_test-player"),
            URLQueryItem(name: "playtime_secs", value: "1777746899"),
            URLQueryItem(name: "slice_num", value: "6"),
            URLQueryItem(name: "song_id", value: "55464"),
            URLQueryItem(name: "source", value: "24"),
            URLQueryItem(name: "type", value: "M"),
        ]
        StubURLProtocol.register(url: components.url!, body: Data())
        let client = makeClient(playerId: "rp3_test-player")
        try await client.updatePause(
            songId: "55464", chan: 0, event: "2869397", audioType: "M",
            sliceNum: "6", playPositionMillis: 21233, playtimeSecs: 1777746899
        )
    }

    func testGaplessSendsExpectedQueryAndDecodesResponse() async throws {
        var components = URLComponents(url: baseURL.appendingPathComponent("api/gapless"), resolvingAgainstBaseURL: false)!
        components.queryItems = [
            URLQueryItem(name: "bitrate", value: "4"),
            URLQueryItem(name: "chan", value: "0"),
            URLQueryItem(name: "numSongs", value: "20"),
            URLQueryItem(name: "player_id", value: "test-player"),
        ]
        StubURLProtocol.register(url: components.url!, body: try loadFixture("gapless_main"))

        let client = makeClient(playerId: "test-player")
        let response = try await client.gapless(channel: 0, bitrate: 4, numSongs: 20)

        XCTAssertEqual(response.songs.first?.eventId, 2872450)
        XCTAssertEqual(response.currentEventId, 2872450)
        XCTAssertEqual(response.bitrateTitle, "flac")
    }

    func testGaplessOmitsPlayerIdWhenAbsent() async throws {
        var components = URLComponents(url: baseURL.appendingPathComponent("api/gapless"), resolvingAgainstBaseURL: false)!
        components.queryItems = [
            URLQueryItem(name: "bitrate", value: "4"),
            URLQueryItem(name: "chan", value: "99"),
            URLQueryItem(name: "numSongs", value: "10"),
        ]
        StubURLProtocol.register(url: components.url!, body: try loadFixture("gapless_main"))

        let client = makeClient(playerId: nil)
        _ = try await client.gapless(channel: 99, bitrate: 4, numSongs: 10)
    }

    func testNon200StatusThrowsInvalidResponse() async throws {
        let url = baseURL.appendingPathComponent("api/list_chan")
        StubURLProtocol.register(url: url, body: Data("server error".utf8), status: 500)

        let client = makeClient()
        do {
            _ = try await client.listChannels()
            XCTFail("Expected RpApiError.invalidResponse")
        } catch let error as RpApiError {
            guard case .invalidResponse(let code, _) = error else {
                XCTFail("Expected .invalidResponse, got \(error)")
                return
            }
            XCTAssertEqual(code, 500)
        }
    }
}


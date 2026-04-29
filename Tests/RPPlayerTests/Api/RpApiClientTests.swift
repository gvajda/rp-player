import XCTest
@testable import RPPlayer

final class RpApiClientTests: XCTestCase {
    private let baseURL = URL(string: "https://api.radioparadise.com/")!

    private func loadFixture(_ name: String) throws -> Data {
        let url = try XCTUnwrap(Bundle.module.url(forResource: "Fixtures/Api/\(name)", withExtension: "json"))
        return try Data(contentsOf: url)
    }

    private func makeClient() -> LiveRpApiClient {
        LiveRpApiClient(
            baseURL: baseURL,
            session: StubURLProtocol.makeSession(),
            cookieProvider: AnonymousCookieProvider(),
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

    func testGetBlockBuildsCorrectQueryAndDecodes() async throws {
        var components = URLComponents(url: baseURL.appendingPathComponent("api/get_block"), resolvingAgainstBaseURL: false)!
        // Match the client's deterministic alpha-by-name ordering of query items.
        components.queryItems = [
            URLQueryItem(name: "bitrate", value: "4"),
            URLQueryItem(name: "chan", value: "0"),
            URLQueryItem(name: "info", value: "true"),
        ]
        StubURLProtocol.register(url: components.url!, body: try loadFixture("get_block"))

        let client = makeClient()
        let block = try await client.getBlock(channel: 0, bitrate: 4, info: true)
        XCTAssertFalse(block.url.isEmpty)
        XCTAssertGreaterThan(block.song.count, 0)
    }

    func testInfoBuildsCorrectQueryAndDecodes() async throws {
        // Read the song_id from the get_block fixture so the query matches what info expects.
        let blockData = try loadFixture("get_block")
        let block = try JSONDecoder.rpDecoder.decode(GetBlock.self, from: blockData)
        let firstSongId = try XCTUnwrap(block.song.values.first?.songId)

        var components = URLComponents(url: baseURL.appendingPathComponent("api/info"), resolvingAgainstBaseURL: false)!
        components.queryItems = [URLQueryItem(name: "song_id", value: firstSongId)]
        StubURLProtocol.register(url: components.url!, body: try loadFixture("info"))

        let client = makeClient()
        let songIdInt = try XCTUnwrap(Int(firstSongId), "PlayListSong.songId must be numeric")
        let info = try await client.info(songId: songIdInt)
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

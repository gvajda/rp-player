import XCTest
@testable import RPPlayer

final class ApiModelsTests: XCTestCase {
    private func loadFixture(_ name: String) throws -> Data {
        let url = try XCTUnwrap(Bundle.module.url(forResource: "Fixtures/Api/\(name)", withExtension: "json"))
        return try Data(contentsOf: url)
    }

    private var decoder: JSONDecoder {
        let d = JSONDecoder()
        d.keyDecodingStrategy = .convertFromSnakeCase
        return d
    }

    func testDecodesListChan() throws {
        let data = try loadFixture("list_chan")
        let channels = try decoder.decode([Channel].self, from: data)
        XCTAssertGreaterThan(channels.count, 0, "list_chan fixture must contain at least one channel")
        let main = try XCTUnwrap(channels.first)
        XCTAssertFalse(main.title.isEmpty)
    }

    func testDecodesGetBlock() throws {
        let data = try loadFixture("get_block")
        let block = try decoder.decode(GetBlock.self, from: data)
        XCTAssertFalse(block.url.isEmpty)
        XCTAssertGreaterThan(block.song.count, 0, "get_block must contain at least one song")
        XCTAssertGreaterThan(block.expiration, 0)
    }

    func testDecodesSongInfo() throws {
        let data = try loadFixture("info")
        let info = try decoder.decode(SongInfo.self, from: data)
        XCTAssertGreaterThan(info.songId, 0)
        XCTAssertFalse(info.artist.isEmpty)
        XCTAssertFalse(info.title.isEmpty)
    }

    func testDecodesAuthStateAnonymous() throws {
        let data = try loadFixture("auth_state_anonymous")
        let auth = try decoder.decode(Auth.self, from: data)
        // Anonymous responses still decode; specific field values vary by API state.
        _ = auth
    }

    func testDecodesRatingSuccess() throws {
        let data = try loadFixture("rating_success")
        let rating = try decoder.decode(Rating.self, from: data)
        XCTAssertEqual(rating.status, "success")
        XCTAssertEqual(rating.songId, 12345)
        XCTAssertEqual(rating.userRating, 7)
    }
}

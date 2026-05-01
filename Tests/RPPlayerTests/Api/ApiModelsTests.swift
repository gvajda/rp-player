import XCTest
@testable import RPPlayer

final class ApiModelsTests: XCTestCase {
    private func loadFixture(_ name: String) throws -> Data {
        let url = try XCTUnwrap(Bundle.module.url(forResource: "Fixtures/Api/\(name)", withExtension: "json"))
        return try Data(contentsOf: url)
    }

    private let decoder = JSONDecoder.rpDecoder

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

    func testDecodesGetBlockPromoTypeWithMissingAlbum() throws {
        let data = try loadFixture("get_block_promo")
        let block = try decoder.decode(GetBlock.self, from: data)
        XCTAssertEqual(block.type, "P")
        XCTAssertEqual(block.song.count, 1)
        let song = try XCTUnwrap(block.song["0"])
        XCTAssertEqual(song.artist, "Commercial-free")
        XCTAssertEqual(song.title, "Listener-supported")
        XCTAssertNil(song.album)
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
        XCTAssertEqual(auth.username, "anonymous")
    }

    func testDecodesRatingSuccess() throws {
        let data = try loadFixture("rating_success")
        let rating = try decoder.decode(Rating.self, from: data)
        XCTAssertEqual(rating.status, "success")
        XCTAssertEqual(rating.songId, 12345)
        XCTAssertEqual(rating.userRating, 7)
    }
}

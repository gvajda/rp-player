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

    func testPlayListSongDecodesNullSliceNum() throws {
        let json = """
        {
          "song_id": "12345",
          "artist": "X",
          "title": "Y",
          "album": "Z",
          "duration": 100000,
          "slice_num": null,
          "type": "M"
        }
        """.data(using: .utf8)!
        let song = try JSONDecoder.rpDecoder.decode(PlayListSong.self, from: json)
        XCTAssertNil(song.sliceNum)
        XCTAssertEqual(song.type, "M")
    }
}

import XCTest
@testable import RPPlayer

final class GaplessResponseTests: XCTestCase {
    func testDecodesMainMixFixture() throws {
        let url = Bundle.module.url(forResource: "gapless_main", withExtension: "json", subdirectory: "Fixtures/Api")
        let data = try Data(contentsOf: XCTUnwrap(url))
        let response = try JSONDecoder.rpDecoder.decode(GaplessResponse.self, from: data)

        XCTAssertEqual(response.channel.chan, "0")
        XCTAssertEqual(response.bitrateTitle, "flac")
        XCTAssertEqual(response.ext, "flac")
        XCTAssertEqual(response.imageBase, "//img.radioparadise.com/")
        XCTAssertEqual(response.currentEventId, 2872450)
        XCTAssertEqual(response.maxGaplessEventId, 2872500)
        XCTAssertEqual(response.slideshowPath, "slideshow/720/")
        XCTAssertGreaterThan(response.songs.count, 5)

        let first = response.songs[0]
        XCTAssertEqual(first.songId, "34608")
        XCTAssertEqual(first.artist, "Stan Getz")
        XCTAssertEqual(first.duration, 251840)
        XCTAssertEqual(first.cue, 163000)
        XCTAssertEqual(first.eventId, 2872450)
        XCTAssertEqual(first.type, "M")
        XCTAssertEqual(first.gaplessUrl, "https://audio-geo.radioparadise.com/chan/0/x/1129/4/g/1129-3.flac")
        XCTAssertEqual(first.sliceNum, 0)
        XCTAssertTrue(first.updateHistory)
        XCTAssertEqual(first.slideshow.count, 27)
    }

    func testDecodesPromoSongInline() throws {
        let url = Bundle.module.url(forResource: "gapless_main", withExtension: "json", subdirectory: "Fixtures/Api")
        let data = try Data(contentsOf: XCTUnwrap(url))
        let response = try JSONDecoder.rpDecoder.decode(GaplessResponse.self, from: data)

        let promo = try XCTUnwrap(response.songs.first(where: { $0.type == "P" }))
        XCTAssertEqual(promo.songId, "0")
        XCTAssertEqual(promo.artist, "Commercial-free")
        XCTAssertFalse(promo.updateHistory)
        XCTAssertFalse(promo.isRateable)
    }
}

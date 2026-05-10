import XCTest
@testable import RPPlayer

final class NowPlayingTests: XCTestCase {
    func testEqualityRequiresAllFieldsMatch() {
        let song = makeGaplessSong(songId: "1", duration: 180_000)
        let np1 = NowPlaying(channelId: 0, song: song, songDurationSeconds: 180)
        let np2 = NowPlaying(channelId: 0, song: song, songDurationSeconds: 180)
        XCTAssertEqual(np1, np2)

        let differentChannel = NowPlaying(channelId: 1, song: song, songDurationSeconds: 180)
        XCTAssertNotEqual(np1, differentChannel)
    }

    func testBlockBitrateLabelUppercasesRawValue() {
        XCTAssertEqual(BlockBitrateLabel.display("flac"), "FLAC")
        XCTAssertEqual(BlockBitrateLabel.display("flacm"), "FLACM")
        XCTAssertEqual(BlockBitrateLabel.display("32k aac"), "32K AAC")
        XCTAssertEqual(BlockBitrateLabel.display("320"), "320")
    }

    func testBlockBitrateLabelTrimsWhitespace() {
        XCTAssertEqual(BlockBitrateLabel.display("  flac  "), "FLAC")
    }

    func testBlockBitrateLabelReturnsNilForEmptyOrMissing() {
        XCTAssertNil(BlockBitrateLabel.display(nil))
        XCTAssertNil(BlockBitrateLabel.display(""))
        XCTAssertNil(BlockBitrateLabel.display("   "))
    }

    func testCoordinatorErrorEquality() {
        XCTAssertEqual(
            PlaybackCoordinatorError.channelNotFound(channelId: 5),
            PlaybackCoordinatorError.channelNotFound(channelId: 5)
        )
        XCTAssertNotEqual(
            PlaybackCoordinatorError.channelNotFound(channelId: 5),
            PlaybackCoordinatorError.channelNotFound(channelId: 6)
        )
        XCTAssertNotEqual(
            PlaybackCoordinatorError.notPlaying,
            PlaybackCoordinatorError.blockHasNoSongs
        )
    }
}

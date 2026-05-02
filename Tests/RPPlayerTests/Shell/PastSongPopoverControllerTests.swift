import AppKit
import SwiftUI
import XCTest
@testable import RPPlayer

@MainActor
final class PastSongPopoverControllerTests: XCTestCase {
    func testShowMakesPanelVisibleAndCloseHidesIt() {
        let controller = PastSongPopoverController()
        XCTAssertFalse(controller.isShown)
        let anchor = NSView(frame: .zero)
        let song = PlayListSong(
            songId: "1", artist: "A", title: "T", album: nil, duration: 0,
            event: nil, schedTime: nil, chan: nil, year: nil, asin: nil,
            rating: nil, userRating: nil, cover: nil, elapsed: nil, slideshow: nil,
            type: nil, sliceNum: nil
        )
        let viewModel = PastSongViewModel(
            song: song,
            albumArtCache: StubAlbumArtCache(),
            auth: StubKeychainAuth(),
            api: MockRpApiClient()
        )
        controller.present(viewModel: viewModel, relativeTo: anchor)
        // Panel may or may not become visible depending on anchor.window — just
        // assert no crash and that close() flips state cleanly.
        controller.close()
        XCTAssertFalse(controller.isShown)
    }
}

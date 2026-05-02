import AppKit
import SwiftUI
import XCTest
@testable import RPPlayer

@MainActor
final class PastSongViewTests: XCTestCase {
    func testHostingControllerRendersWithoutCrash() {
        let song = PlayListSong(
            songId: "1", artist: "A", title: "T", album: "Al", duration: 0,
            event: nil, schedTime: nil, chan: nil, year: nil, asin: nil,
            rating: nil, userRating: nil, cover: nil, elapsed: nil, slideshow: nil
        )
        let viewModel = PastSongViewModel(
            song: song,
            albumArtCache: StubAlbumArtCache(),
            auth: StubKeychainAuth(),
            api: MockRpApiClient()
        )
        let host = NSHostingController(rootView: PastSongView(viewModel: viewModel))
        host.loadView()
        XCTAssertNotNil(host.view)
        XCTAssertGreaterThan(host.view.intrinsicContentSize.width, 0)
    }
}

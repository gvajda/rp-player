import AppKit
import SwiftUI
import XCTest
@testable import RPPlayer

@MainActor
final class SongTitleRowTests: XCTestCase {
    func testHostingControllerRendersWithoutCrash() {
        let view = SongTitleRow(
            title: "Title",
            artist: "Artist",
            album: "Album",
            currentRating: 7,
            isSignedIn: true,
            onRate: { _ in }
        )
        let host = NSHostingController(rootView: view)
        host.loadView()
        XCTAssertNotNil(host.view)
    }

    func testRendersWithNilAlbumAndSignedOut() {
        let view = SongTitleRow(
            title: "T",
            artist: "A",
            album: nil,
            currentRating: nil,
            isSignedIn: false,
            onRate: { _ in }
        )
        let host = NSHostingController(rootView: view)
        host.loadView()
        XCTAssertNotNil(host.view)
    }
}

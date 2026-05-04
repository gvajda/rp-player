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
            year: "2024",
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
            year: nil,
            currentRating: nil,
            isSignedIn: false,
            onRate: { _ in }
        )
        let host = NSHostingController(rootView: view)
        host.loadView()
        XCTAssertNotNil(host.view)
    }

    func testRendersWithYearOnlyAndAlbumOnly() {
        let yearOnly = SongTitleRow(
            title: "T", artist: "A", album: nil, year: "1972",
            currentRating: nil, isSignedIn: false, onRate: { _ in }
        )
        let albumOnly = SongTitleRow(
            title: "T", artist: "A", album: "Album", year: nil,
            currentRating: nil, isSignedIn: false, onRate: { _ in }
        )
        let host1 = NSHostingController(rootView: yearOnly)
        host1.loadView()
        XCTAssertNotNil(host1.view)
        let host2 = NSHostingController(rootView: albumOnly)
        host2.loadView()
        XCTAssertNotNil(host2.view)
    }
}

import XCTest
@testable import RPPlayer

@MainActor
final class UpcomingProgramViewModelSkipTests: XCTestCase {
    private func makeVM(_ settings: AppSettings, _ api: MockRpApiClient) -> UpcomingProgramViewModel {
        UpcomingProgramViewModel(
            api: api,
            albumArtCache: StubAlbumArtCache(),
            configStore: StubConfigStore(initial: settings),
            paletteExtractor: StubAmbientPaletteExtractor()
        )
    }

    func testRowsMarkedSkippedByPolicy() async throws {
        var s = AppSettings.default
        s.skipLowRatedEnabled = true
        s.skipRatingThreshold = 5
        let api = MockRpApiClient()
        await api.setListChannelsResponse([Channel(chan: "0", title: "Main", streamName: "main", bannerUrl: nil, slug: nil, image: nil)])
        await api.setGaplessByChannel([0: makeGaplessResponse(songs: [
            makeGaplessSong(songId: "good", eventId: 100, userRating: 8),
            makeGaplessSong(songId: "bad",  eventId: 101, userRating: 2),
            makeGaplessSong(songId: "new",  eventId: 102, userRating: 0),
        ])])
        let vm = makeVM(s, api)
        await vm.load()

        let rows = vm.columns.first?.songs ?? []
        XCTAssertEqual(rows.first(where: { $0.song.songId == "good" })?.isSkipped, false)
        XCTAssertEqual(rows.first(where: { $0.song.songId == "bad" })?.isSkipped, true)
        XCTAssertEqual(rows.first(where: { $0.song.songId == "new" })?.isSkipped, false)
    }

    func testNoRowsSkippedWhenDisabled() async throws {
        let s = AppSettings.default  // skipLowRatedEnabled defaults false
        let api = MockRpApiClient()
        await api.setListChannelsResponse([Channel(chan: "0", title: "Main", streamName: "main", bannerUrl: nil, slug: nil, image: nil)])
        await api.setGaplessByChannel([0: makeGaplessResponse(songs: [
            makeGaplessSong(songId: "bad", eventId: 101, userRating: 2),
        ])])
        let vm = makeVM(s, api)
        await vm.load()
        XCTAssertEqual(vm.columns.first?.songs.first?.isSkipped, false)
    }
}

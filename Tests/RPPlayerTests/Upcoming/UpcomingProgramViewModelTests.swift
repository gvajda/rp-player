import XCTest
import SwiftUI
@testable import RPPlayer

@MainActor
final class UpcomingProgramViewModelTests: XCTestCase {
    // MARK: - Helpers

    private func makeChannel(id: Int) -> Channel {
        Channel(chan: String(id), title: "Channel \(id)", streamName: nil,
                bannerUrl: nil, slug: nil, image: nil)
    }

    private func makePromoBlock() -> GetBlock {
        let promo = PlayListSong(
            songId: "0", artist: "Commercial-free", title: "Listener-supported",
            album: nil, duration: 5_000, event: nil,
            schedTime: nil, chan: nil, year: nil, asin: nil,
            rating: nil, userRating: nil, cover: nil,
            elapsed: 0, slideshow: nil, type: "P", sliceNum: nil
        )
        return GetBlock(
            url: "https://stream.example.com/stream",
            chan: "0", bitrate: "flac", cue: 0, expiration: 9_999_999_999,
            length: nil, imageBase: "https://img.radioparadise.com/",
            song: ["0": promo], channel: nil,
            event: "200", endEvent: "201", type: "P", ext: nil
        )
    }

    private func makeBlock(songs: Int = 3) -> GetBlock {
        let songDict: [String: PlayListSong] = Dictionary(
            uniqueKeysWithValues: (0..<songs).map { i in
                let song = PlayListSong(
                    songId: "song\(i)", artist: "Artist \(i)", title: "Title \(i)",
                    album: "Album \(i)", duration: 60_000, event: nil,
                    schedTime: nil, chan: nil, year: nil, asin: nil,
                    rating: nil, userRating: nil, cover: nil,
                    elapsed: i * 60_000, slideshow: nil, type: "M", sliceNum: nil
                )
                return (String(i), song)
            }
        )
        return GetBlock(
            url: "https://stream.example.com/stream",
            chan: "0",
            bitrate: "flac",
            cue: 0,
            expiration: 9_999_999_999,
            length: nil,
            imageBase: "https://img.radioparadise.com/",
            song: songDict,
            channel: nil,
            event: "123",
            endEvent: "456",
            type: "M",
            ext: nil
        )
    }

    private func makeVM(
        api: MockRpApiClient,
        configStore: StubConfigStore = StubConfigStore(initial: .default),
        artCache: StubAlbumArtCache = StubAlbumArtCache(),
        palette: StubAmbientPaletteExtractor = StubAmbientPaletteExtractor()
    ) -> UpcomingProgramViewModel {
        UpcomingProgramViewModel(
            api: api,
            albumArtCache: artCache,
            configStore: configStore,
            paletteExtractor: palette
        )
    }

    // MARK: - Tests

    func testLoadPopulatesColumns() async throws {
        let api = MockRpApiClient()
        let channels = [makeChannel(id: 0), makeChannel(id: 1)]
        await api.setListChannelsResponse(channels)
        await api.setGetBlockResponses([makeBlock(songs: 5), makeBlock(songs: 5)])

        var settings = AppSettings.default
        settings.upcomingRowCount = 3
        let vm = makeVM(api: api, configStore: StubConfigStore(initial: settings))
        await vm.load()

        XCTAssertEqual(vm.columns.count, 2)
        XCTAssertEqual(vm.columns[0].songs.count, 3)
        XCTAssertEqual(vm.columns[1].songs.count, 3)
    }

    func testLoadSkipsHiddenChannels() async throws {
        let api = MockRpApiClient()
        let channels = [makeChannel(id: 0), makeChannel(id: 1), makeChannel(id: 2)]
        await api.setListChannelsResponse(channels)
        await api.setGetBlockResponses([makeBlock(), makeBlock()])

        var settings = AppSettings.default
        settings.upcomingHiddenChannelIds = [1]
        let vm = makeVM(api: api, configStore: StubConfigStore(initial: settings))
        await vm.load()

        XCTAssertEqual(vm.columns.count, 2)
        XCTAssertFalse(vm.columns.contains { $0.id == 1 })
    }

    func testLoadAlwaysExcludesChannel42And99() async throws {
        let api = MockRpApiClient()
        let channels = [makeChannel(id: 0), makeChannel(id: 42), makeChannel(id: 99)]
        await api.setListChannelsResponse(channels)
        await api.setGetBlockResponses([makeBlock()])

        let vm = makeVM(api: api)
        await vm.load()

        XCTAssertEqual(vm.columns.count, 1)
        XCTAssertEqual(vm.columns[0].id, 0)
    }

    func testLoadSetsLastUpdated() async throws {
        let api = MockRpApiClient()
        await api.setListChannelsResponse([makeChannel(id: 0)])
        await api.setGetBlockResponses([makeBlock()])

        let vm = makeVM(api: api)
        XCTAssertNil(vm.lastUpdated)
        await vm.load()
        XCTAssertNotNil(vm.lastUpdated)
    }

    func testLoadIsNotLoadingAfterCompletion() async throws {
        let api = MockRpApiClient()
        await api.setListChannelsResponse([makeChannel(id: 0)])
        await api.setGetBlockResponses([makeBlock()])

        let vm = makeVM(api: api)
        await vm.load()
        XCTAssertFalse(vm.isLoading)
    }

    func testRefreshReplacesColumns() async throws {
        let api = MockRpApiClient()
        let channels = [makeChannel(id: 0)]
        await api.setListChannelsResponse(channels)
        await api.setGetBlockResponses([makeBlock(songs: 2)])

        let vm = makeVM(api: api)
        await vm.load()
        XCTAssertEqual(vm.columns[0].songs.count, 2)

        await api.setListChannelsResponse(channels)
        await api.setGetBlockResponses([makeBlock(songs: 4)])
        await vm.refresh()
        XCTAssertEqual(vm.columns[0].songs.count, 4)
    }

    func testChannelFetchErrorProducesEmptyColumnAndSetsErrorMessage() async throws {
        let api = MockRpApiClient()
        let channels = [makeChannel(id: 0), makeChannel(id: 1)]
        await api.setListChannelsResponse(channels)
        // Only one response: channel 0 succeeds, channel 1 exhausts the queue and throws
        await api.setGetBlockResponses([makeBlock(songs: 3)])

        let vm = makeVM(api: api)
        await vm.load()

        XCTAssertNotNil(vm.errorMessage)
        XCTAssertEqual(vm.columns.count, 2)
        let songCounts = Set(vm.columns.map { $0.songs.count })
        XCTAssertTrue(songCounts.contains(0), "Expected at least one empty column")
        XCTAssertTrue(vm.columns.contains { $0.songs.count > 0 }, "Expected at least one populated column")
    }

    func testLoadCapsRowsAtUpcomingRowCount() async throws {
        let api = MockRpApiClient()
        await api.setListChannelsResponse([makeChannel(id: 0)])
        await api.setGetBlockResponses([makeBlock(songs: 10)])

        var settings = AppSettings.default
        settings.upcomingRowCount = 4
        let vm = makeVM(api: api, configStore: StubConfigStore(initial: settings))
        await vm.load()

        XCTAssertEqual(vm.columns[0].songs.count, 4)
    }

    func testLoadFiltersOutPromoSongs() async throws {
        let api = MockRpApiClient()
        await api.setListChannelsResponse([makeChannel(id: 0)])
        // Block with 2 music songs + 1 promo; only 2 music songs should appear
        let promoSong = PlayListSong(
            songId: "0", artist: "Commercial-free", title: "Listener-supported",
            album: nil, duration: 5_000, event: nil,
            schedTime: nil, chan: nil, year: nil, asin: nil,
            rating: nil, userRating: nil, cover: nil,
            elapsed: 0, slideshow: nil, type: "P", sliceNum: nil
        )
        let musicSong0 = PlayListSong(
            songId: "song0", artist: "A", title: "T0", album: "Al", duration: 60_000,
            event: nil, schedTime: nil, chan: nil, year: nil, asin: nil,
            rating: nil, userRating: nil, cover: nil, elapsed: 0,
            slideshow: nil, type: "M", sliceNum: nil
        )
        let musicSong1 = PlayListSong(
            songId: "song1", artist: "B", title: "T1", album: "Al", duration: 60_000,
            event: nil, schedTime: nil, chan: nil, year: nil, asin: nil,
            rating: nil, userRating: nil, cover: nil, elapsed: 60_000,
            slideshow: nil, type: "M", sliceNum: nil
        )
        let mixedBlock = GetBlock(
            url: "https://stream.example.com/stream",
            chan: "0", bitrate: "flac", cue: 0, expiration: 9_999_999_999,
            length: nil, imageBase: "https://img.radioparadise.com/",
            song: ["0": promoSong, "1": musicSong0, "2": musicSong1],
            channel: nil, event: "100", endEvent: nil, type: "M", ext: nil
        )
        await api.setGetBlockResponses([mixedBlock])

        var settings = AppSettings.default
        settings.upcomingRowCount = 3
        let vm = makeVM(api: api, configStore: StubConfigStore(initial: settings))
        await vm.load()

        XCTAssertEqual(vm.columns[0].songs.count, 2)
        XCTAssertFalse(vm.columns[0].songs.contains { $0.song.songId == "0" })
    }

    func testLoadFetchesNextBlockWhenInsufficientSongs() async throws {
        // rowCount=4, each block has 2 songs → expects 2 getBlock calls, 4 songs total
        let api = MockRpApiClient()
        await api.setListChannelsResponse([makeChannel(id: 0)])
        // makeBlock returns endEvent "456", so second fetch uses event=456
        await api.setGetBlockResponses([makeBlock(songs: 2), makeBlock(songs: 2)])

        var settings = AppSettings.default
        settings.upcomingRowCount = 4
        let vm = makeVM(api: api, configStore: StubConfigStore(initial: settings))
        await vm.load()

        XCTAssertEqual(vm.columns[0].songs.count, 4)
    }
}

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

    private func makeMusicSongs(count: Int, startId: Int = 0) -> [GaplessSong] {
        (0..<count).map { i in
            makeGaplessSong(songId: "song\(startId + i)", type: "M")
        }
    }

    private func makePromoSong(id: String = "0") -> GaplessSong {
        makeGaplessSong(songId: id, type: "P")
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
        await api.setGaplessByChannel([
            0: makeGaplessResponse(songs: makeMusicSongs(count: 5), chan: "0"),
            1: makeGaplessResponse(songs: makeMusicSongs(count: 5, startId: 10), chan: "1")
        ])

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
        await api.setGaplessByChannel([
            0: makeGaplessResponse(songs: makeMusicSongs(count: 3), chan: "0"),
            2: makeGaplessResponse(songs: makeMusicSongs(count: 3, startId: 20), chan: "2")
        ])

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
        await api.setGaplessByChannel([
            0: makeGaplessResponse(songs: makeMusicSongs(count: 3), chan: "0")
        ])

        let vm = makeVM(api: api)
        await vm.load()

        XCTAssertEqual(vm.columns.count, 1)
        XCTAssertEqual(vm.columns[0].id, 0)
    }

    func testLoadSetsLastUpdated() async throws {
        let api = MockRpApiClient()
        await api.setListChannelsResponse([makeChannel(id: 0)])
        await api.setGaplessResponse(makeGaplessResponse(songs: makeMusicSongs(count: 3)))

        let vm = makeVM(api: api)
        XCTAssertNil(vm.lastUpdated)
        await vm.load()
        XCTAssertNotNil(vm.lastUpdated)
    }

    func testLoadIsNotLoadingAfterCompletion() async throws {
        let api = MockRpApiClient()
        await api.setListChannelsResponse([makeChannel(id: 0)])
        await api.setGaplessResponse(makeGaplessResponse(songs: makeMusicSongs(count: 3)))

        let vm = makeVM(api: api)
        await vm.load()
        XCTAssertFalse(vm.isLoading)
    }

    func testRefreshReplacesColumns() async throws {
        let api = MockRpApiClient()
        let channels = [makeChannel(id: 0)]
        await api.setListChannelsResponse(channels)
        await api.setGaplessResponse(makeGaplessResponse(songs: makeMusicSongs(count: 2)))

        let vm = makeVM(api: api)
        await vm.load()
        XCTAssertEqual(vm.columns[0].songs.count, 2)

        await api.setListChannelsResponse(channels)
        await api.setGaplessResponse(makeGaplessResponse(songs: makeMusicSongs(count: 4)))
        await vm.refresh()
        XCTAssertEqual(vm.columns[0].songs.count, 4)
    }

    func testChannelFetchErrorProducesEmptyColumnAndSetsErrorMessage() async throws {
        let api = MockRpApiClient()
        let channels = [makeChannel(id: 0), makeChannel(id: 1)]
        await api.setListChannelsResponse(channels)
        // Only channel 0 has a response; channel 1 will throw (no response in queue)
        await api.setGaplessByChannel([
            0: makeGaplessResponse(songs: makeMusicSongs(count: 3), chan: "0")
        ])

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
        await api.setGaplessResponse(makeGaplessResponse(songs: makeMusicSongs(count: 20)))

        var settings = AppSettings.default
        settings.upcomingRowCount = 4
        let vm = makeVM(api: api, configStore: StubConfigStore(initial: settings))
        await vm.load()

        XCTAssertEqual(vm.columns[0].songs.count, 4)
    }

    func testLoadFiltersOutPromoSongs() async throws {
        let api = MockRpApiClient()
        await api.setListChannelsResponse([makeChannel(id: 0)])
        // 2 music songs + 1 promo; only 2 music songs should appear
        let songs: [GaplessSong] = [
            makeGaplessSong(songId: "0", type: "P"),
            makeGaplessSong(songId: "song0", type: "M"),
            makeGaplessSong(songId: "song1", type: "M")
        ]
        await api.setGaplessResponse(makeGaplessResponse(songs: songs))

        var settings = AppSettings.default
        settings.upcomingRowCount = 3
        let vm = makeVM(api: api, configStore: StubConfigStore(initial: settings))
        await vm.load()

        XCTAssertEqual(vm.columns[0].songs.count, 2)
        XCTAssertFalse(vm.columns[0].songs.contains { $0.song.songId == "0" })
    }

    func testLoadFetchesOneCallPerVisibleChannel() async throws {
        let api = MockRpApiClient()
        let channels = [makeChannel(id: 0), makeChannel(id: 1), makeChannel(id: 2)]
        await api.setListChannelsResponse(channels)
        await api.setGaplessByChannel([
            0: makeGaplessResponse(songs: makeMusicSongs(count: 3), chan: "0"),
            1: makeGaplessResponse(songs: makeMusicSongs(count: 3, startId: 10), chan: "1"),
            2: makeGaplessResponse(songs: makeMusicSongs(count: 3, startId: 20), chan: "2")
        ])

        let vm = makeVM(api: api)
        await vm.load()

        let gaplessCalls = await api.calls.filter {
            if case .gapless = $0 { return true }
            return false
        }
        XCTAssertEqual(gaplessCalls.count, 3, "Expected exactly one gapless call per enabled channel")
    }

    func testCurrentChannelAndSongMirrorCoordinator() async throws {
        let api = MockRpApiClient()
        await api.setListChannelsResponse([makeChannel(id: 0)])
        await api.setGaplessResponse(makeGaplessResponse(songs: makeMusicSongs(count: 3)))
        let coord = MockPlaybackCoordinator()
        let vm = UpcomingProgramViewModel(
            api: api,
            albumArtCache: StubAlbumArtCache(),
            configStore: StubConfigStore(initial: .default),
            paletteExtractor: StubAmbientPaletteExtractor(),
            coordinator: coord
        )

        let np = makeNowPlaying(channelId: 7, songId: "abc-123")
        await coord.setNowPlaying(np)
        await vm.load()
        try await Task.sleep(nanoseconds: 80_000_000)

        XCTAssertEqual(vm.currentChannelId, 7)
        XCTAssertEqual(vm.currentSongId, "abc-123")

        let next = makeNowPlaying(channelId: 3, songId: "xyz-9")
        await coord.setNowPlaying(next)
        try await Task.sleep(nanoseconds: 80_000_000)
        XCTAssertEqual(vm.currentChannelId, 3)
        XCTAssertEqual(vm.currentSongId, "xyz-9")
    }

    func testSelectChannelInvokesHandler() async throws {
        let api = MockRpApiClient()
        await api.setListChannelsResponse([makeChannel(id: 0)])
        let received = LockedArray<Int>()
        let vm = UpcomingProgramViewModel(
            api: api,
            albumArtCache: StubAlbumArtCache(),
            configStore: StubConfigStore(initial: .default),
            paletteExtractor: StubAmbientPaletteExtractor(),
            selectChannelHandler: { id in received.append(id) }
        )

        vm.selectChannel(2)
        vm.selectChannel(5)
        try await Task.sleep(nanoseconds: 50_000_000)

        XCTAssertEqual(received.values, [2, 5])
    }
}

@MainActor
private func makeNowPlaying(channelId: Int, songId: String) -> NowPlaying {
    NowPlaying(
        channelId: channelId,
        song: makeGaplessSong(songId: songId),
        songDurationSeconds: 180
    )
}

private final class LockedArray<T: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [T] = []
    func append(_ value: T) {
        lock.lock(); defer { lock.unlock() }
        storage.append(value)
    }
    var values: [T] {
        lock.lock(); defer { lock.unlock() }
        return storage
    }
}

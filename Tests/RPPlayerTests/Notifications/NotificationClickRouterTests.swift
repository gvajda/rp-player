import XCTest
import UserNotifications
@testable import RPPlayer

@MainActor
final class NotificationClickRouterTests: XCTestCase {
    private func makeNowPlaying(songId: String) -> NowPlaying {
        NowPlaying(
            channelId: 0, song: makeGaplessSong(songId: songId, duration: 0), songDurationSeconds: 0
        )
    }

    func testCurrentSongOpensMainPopover() async {
        let coordinator = MockPlaybackCoordinator()
        await coordinator.setNowPlaying(makeNowPlaying(songId: "55"))
        let registry = SongRegistry()
        let api = MockRpApiClient()
        var mainCalled = 0
        var pastSongs: [PlayListSong] = []
        let router = NotificationClickRouter(
            coordinator: coordinator,
            registry: registry,
            api: api,
            mainPresenter: { mainCalled += 1 },
            pastSongPresenter: { song in pastSongs.append(song) }
        )
        await router.route(requestIdentifier: "abc|55")
        XCTAssertEqual(mainCalled, 1)
        XCTAssertTrue(pastSongs.isEmpty)
    }

    func testCachedPastSongOpensPastSongPopover() async {
        let coordinator = MockPlaybackCoordinator()
        await coordinator.setNowPlaying(makeNowPlaying(songId: "55"))
        let registry = SongRegistry()
        await registry.record(PlayListSong(from: makeGaplessSong(songId: "99", duration: 0)))
        var mainCalled = 0
        var pastSongs: [PlayListSong] = []
        let router = NotificationClickRouter(
            coordinator: coordinator,
            registry: registry,
            api: MockRpApiClient(),
            mainPresenter: { mainCalled += 1 },
            pastSongPresenter: { song in pastSongs.append(song) }
        )
        await router.route(requestIdentifier: "abc|99")
        XCTAssertEqual(mainCalled, 0)
        XCTAssertEqual(pastSongs.map(\.songId), ["99"])
    }

    func testApiInfoFallbackOnCacheMiss() async {
        let coordinator = MockPlaybackCoordinator()
        let registry = SongRegistry()
        let api = MockRpApiClient()
        let stubInfo = SongInfo(
            songId: 12345, artist: "From API", title: "From API", album: nil, asin: nil,
            avgRating: nil, numRatings: nil, userRating: nil,
            webLink: nil, wikiLink: nil, lyricsAvail: nil, lyrics: nil,
            medCover: nil, largeCover: nil, releaseDate: nil, length: nil,
            plays30: nil, slideshow: nil
        )
        await api.setInfoResponse(stubInfo)
        var pastSongs: [PlayListSong] = []
        let router = NotificationClickRouter(
            coordinator: coordinator,
            registry: registry,
            api: api,
            mainPresenter: {},
            pastSongPresenter: { song in pastSongs.append(song) }
        )
        await router.route(requestIdentifier: "uuid|12345")
        XCTAssertEqual(pastSongs.map(\.artist), ["From API"])
    }

    func testApiInfoFailureFallsBackToMainPopover() async {
        let coordinator = MockPlaybackCoordinator()
        let registry = SongRegistry()
        let api = MockRpApiClient()
        // No setInfoResponse → MockRpApiClient.info throws RpApiError.network.
        var mainCalled = 0
        let router = NotificationClickRouter(
            coordinator: coordinator,
            registry: registry,
            api: api,
            mainPresenter: { mainCalled += 1 },
            pastSongPresenter: { _ in }
        )
        await router.route(requestIdentifier: "uuid|99999")
        XCTAssertEqual(mainCalled, 1)
    }
}

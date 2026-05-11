import AppKit
import XCTest
@testable import RPPlayer

@MainActor
final class NotificationCoordinatorTests: XCTestCase {
    private var coordinator: MockPlaybackCoordinator!
    private var cache: MockAlbumArtCache!
    private var service: MockNotificationService!
    private var sut: NotificationCoordinator!

    override func setUp() async throws {
        coordinator = MockPlaybackCoordinator()
        cache = MockAlbumArtCache()
        service = MockNotificationService()
        sut = NotificationCoordinator(
            coordinator: coordinator,
            cache: cache,
            service: service,
            registry: SongRegistry(),
            notificationsEnabled: { true },
            channelTitle: { _ in "The Main Mix" },
            cachedFileURL: { coverPath in
                URL(fileURLWithPath: "/tmp/\(coverPath.replacingOccurrences(of: "/", with: "_"))")
            }
        )
    }

    override func tearDown() async throws {
        await sut.stop()
    }

    func testNotifiesOnNowPlayingEmissionWhenEnabled() async throws {
        await sut.start()
        await coordinator.setNowPlaying(.fixture(title: "Song", artist: "Artist", album: "Album"))
        try await Task.sleep(nanoseconds: 50_000_000)
        let calls = await service.notifyCalls
        XCTAssertEqual(calls.count, 1)
        XCTAssertEqual(calls[0].title, "Artist — Song")
        XCTAssertEqual(calls[0].subtitle, "Album · The Main Mix")
    }

    func testSkipsNotificationWhenDisabled() async throws {
        sut = NotificationCoordinator(
            coordinator: coordinator,
            cache: cache,
            service: service,
            registry: SongRegistry(),
            notificationsEnabled: { false },
            channelTitle: { _ in "Main" },
            cachedFileURL: { _ in nil }
        )
        await sut.start()
        await coordinator.setNowPlaying(.fixture())
        try await Task.sleep(nanoseconds: 50_000_000)
        let calls = await service.notifyCalls
        XCTAssertTrue(calls.isEmpty)
    }

    func testStopCancelsSubscription() async throws {
        await sut.start()
        await sut.stop()
        await coordinator.setNowPlaying(.fixture())
        try await Task.sleep(nanoseconds: 50_000_000)
        let calls = await service.notifyCalls
        XCTAssertTrue(calls.isEmpty)
    }

    func testDedupesBackToBackEmissionsForSameSong() async throws {
        await sut.start()
        // Coordinator emits NowPlaying twice per song-start (synchronous emit from play/skip/resume,
        // then again from syncQueueHeadFromMpv on mpv's MPV_EVENT_START_FILE). Notify only once.
        await coordinator.setNowPlaying(.fixture(songId: "42", eventId: 555))
        try await Task.sleep(nanoseconds: 50_000_000)
        await coordinator.setNowPlaying(.fixture(songId: "42", eventId: 555))
        try await Task.sleep(nanoseconds: 50_000_000)
        let calls = await service.notifyCalls
        XCTAssertEqual(calls.count, 1)
    }

    func testNotifiesAgainWhenEventIdChanges() async throws {
        await sut.start()
        await coordinator.setNowPlaying(.fixture(songId: "42", eventId: 100))
        try await Task.sleep(nanoseconds: 50_000_000)
        await coordinator.setNowPlaying(.fixture(songId: "42", eventId: 101))
        try await Task.sleep(nanoseconds: 50_000_000)
        let calls = await service.notifyCalls
        XCTAssertEqual(calls.count, 2)
    }

    func testNotifiesAgainWhenChannelChanges() async throws {
        await sut.start()
        await coordinator.setNowPlaying(.fixture(songId: "42", eventId: 555, channelId: 0))
        try await Task.sleep(nanoseconds: 50_000_000)
        await coordinator.setNowPlaying(.fixture(songId: "42", eventId: 555, channelId: 1))
        try await Task.sleep(nanoseconds: 50_000_000)
        let calls = await service.notifyCalls
        XCTAssertEqual(calls.count, 2)
    }

    func testRecordsSongInRegistryEvenWhenNotificationsDisabled() async throws {
        let registry = SongRegistry()
        let sut = NotificationCoordinator(
            coordinator: coordinator,
            cache: cache,
            service: service,
            registry: registry,
            notificationsEnabled: { false },
            channelTitle: { _ in nil },
            cachedFileURL: { _ in nil }
        )
        await sut.start()
        await coordinator.setNowPlaying(.fixture(songId: "777"))
        try await Task.sleep(nanoseconds: 50_000_000)
        let recorded = await registry.lookup(songId: "777")
        XCTAssertNotNil(recorded, "registry should contain the song even when notifications are disabled")
        await sut.stop()
    }
}

actor MockAlbumArtCache: AlbumArtCache {
    var calls: [String] = []
    func image(for coverPath: String) async -> NSImage? {
        calls.append(coverPath)
        return nil
    }
}

actor MockNotificationService: NotificationService {
    struct NotifyCall: Equatable, Sendable {
        let title: String
        let subtitle: String
        let attachmentURL: URL?
        let identifierSuffix: String?
    }
    var notifyCalls: [NotifyCall] = []
    var authorizationResult: Bool = true

    func requestAuthorization() async throws -> Bool { authorizationResult }
    func notify(title: String, subtitle: String, attachmentURL: URL?, identifierSuffix: String?) async throws {
        notifyCalls.append(NotifyCall(title: title, subtitle: subtitle, attachmentURL: attachmentURL, identifierSuffix: identifierSuffix))
    }
}

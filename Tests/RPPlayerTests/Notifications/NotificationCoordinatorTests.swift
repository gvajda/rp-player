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
    }
    var notifyCalls: [NotifyCall] = []
    var authorizationResult: Bool = true

    func requestAuthorization() async throws -> Bool { authorizationResult }
    func notify(title: String, subtitle: String, attachmentURL: URL?) async throws {
        notifyCalls.append(NotifyCall(title: title, subtitle: subtitle, attachmentURL: attachmentURL))
    }
}

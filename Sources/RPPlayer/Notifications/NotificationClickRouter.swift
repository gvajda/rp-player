import AppKit
import Foundation
import UserNotifications

@MainActor
public final class NotificationClickRouter: NSObject, UNUserNotificationCenterDelegate {
    public typealias MainPresenter = @MainActor () -> Void
    public typealias PastSongPresenter = @MainActor (PlayListSong) -> Void

    private let coordinator: any PlaybackCoordinator
    private let registry: SongRegistry
    private let api: any RpApiClient
    private let mainPresenter: MainPresenter
    private let pastSongPresenter: PastSongPresenter

    public init(
        coordinator: any PlaybackCoordinator,
        registry: SongRegistry,
        api: any RpApiClient,
        mainPresenter: @escaping MainPresenter,
        pastSongPresenter: @escaping PastSongPresenter
    ) {
        self.coordinator = coordinator
        self.registry = registry
        self.api = api
        self.mainPresenter = mainPresenter
        self.pastSongPresenter = pastSongPresenter
    }

    public func route(requestIdentifier: String) async {
        guard let songId = LiveNotificationService.extractSongId(from: requestIdentifier) else {
            mainPresenter()
            return
        }
        if let np = await coordinator.nowPlaying, np.song.songId == songId {
            mainPresenter()
            return
        }
        if let cached = await registry.lookup(songId: songId) {
            pastSongPresenter(cached)
            return
        }
        guard let id = Int(songId) else {
            mainPresenter()
            return
        }
        do {
            let info = try await api.info(songId: id)
            pastSongPresenter(PlayListSong(from: info))
        } catch {
            mainPresenter()
        }
    }

    public nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping @Sendable () -> Void
    ) {
        let identifier = response.notification.request.identifier
        Task { @MainActor in
            await self.route(requestIdentifier: identifier)
            completionHandler()
        }
    }
}

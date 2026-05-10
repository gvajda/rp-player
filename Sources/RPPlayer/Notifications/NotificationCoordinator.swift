import AppKit
import Foundation

@MainActor
public final class NotificationCoordinator {
    public typealias NotificationsEnabledProvider = @Sendable () async -> Bool
    public typealias ChannelTitleProvider = @Sendable (Int) async -> String?
    public typealias CachedFileURLProvider = @Sendable (String) async -> URL?

    private let coordinator: any PlaybackCoordinator
    private let cache: any AlbumArtCache
    private let service: any NotificationService
    private let registry: SongRegistry
    private let notificationsEnabled: NotificationsEnabledProvider
    private let channelTitle: ChannelTitleProvider
    private let cachedFileURL: CachedFileURLProvider
    private var subscriptionTask: Task<Void, Never>?

    public init(
        coordinator: any PlaybackCoordinator,
        cache: any AlbumArtCache,
        service: any NotificationService,
        registry: SongRegistry,
        notificationsEnabled: @escaping NotificationsEnabledProvider,
        channelTitle: @escaping ChannelTitleProvider,
        cachedFileURL: @escaping CachedFileURLProvider
    ) {
        self.coordinator = coordinator
        self.cache = cache
        self.service = service
        self.registry = registry
        self.notificationsEnabled = notificationsEnabled
        self.channelTitle = channelTitle
        self.cachedFileURL = cachedFileURL
    }

    public func start() async {
        subscriptionTask?.cancel()
        let stream = await coordinator.nowPlayingUpdates
        subscriptionTask = Task { [weak self] in
            // AsyncStream iteration does not auto-check Task cancellation; stop() needs explicit observation.
            for await np in stream {
                if Task.isCancelled { return }
                guard let self else { return }
                await self.handle(np)
            }
        }
    }

    public func stop() async {
        subscriptionTask?.cancel()
        subscriptionTask = nil
    }

    private func handle(_ np: NowPlaying) async {
        await registry.record(PlayListSong(from: np.song))
        guard await notificationsEnabled() else { return }
        let title = "\(np.song.artist) — \(np.song.title)"
        let subtitlePrefix = np.song.album ?? ""
        let channel = await channelTitle(np.channelId) ?? ""
        let subtitle: String
        if subtitlePrefix.isEmpty {
            subtitle = channel
        } else if channel.isEmpty {
            subtitle = subtitlePrefix
        } else {
            subtitle = "\(subtitlePrefix) · \(channel)"
        }

        var attachmentURL: URL?
        if let cover = np.song.coverLarge ?? np.song.coverMedium {
            _ = await cache.image(for: cover)
            attachmentURL = await cachedFileURL(cover)
        }

        do {
            try await service.notify(
                title: title,
                subtitle: subtitle,
                attachmentURL: attachmentURL,
                identifierSuffix: np.song.songId
            )
        } catch {
            // The notification daemon refuses unbundled processes; tolerate.
        }
    }
}

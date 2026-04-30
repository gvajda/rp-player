import AppKit
import Combine
import Foundation

@MainActor
final class MiniPlayerViewModel: ObservableObject {
    @Published private(set) var nowPlaying: NowPlaying?
    @Published private(set) var isPlaying: Bool = false
    @Published private(set) var channels: [Channel] = []
    @Published private(set) var selectedChannelId: Int
    @Published private(set) var errorMessage: String?
    @Published private(set) var currentArt: NSImage?
    @Published private(set) var isSignedIn: Bool = false
    @Published private(set) var currentRating: Int?

    typealias PersistChannelId = @Sendable (Int) async -> Void

    private let coordinator: any PlaybackCoordinator
    private let api: any RpApiClient
    private let albumArtCache: any AlbumArtCache
    private let auth: any KeychainAuth
    private let openSettingsAction: @MainActor () -> Void
    private let persistChannelId: PersistChannelId
    private var subscriptionTask: Task<Void, Never>?
    private var inFlightChannelId: Int?

    init(
        coordinator: any PlaybackCoordinator,
        api: any RpApiClient,
        initialChannelId: Int,
        albumArtCache: any AlbumArtCache,
        auth: any KeychainAuth,
        openSettings: @escaping @MainActor () -> Void,
        persistChannelId: @escaping PersistChannelId = { _ in }
    ) {
        self.coordinator = coordinator
        self.api = api
        self.albumArtCache = albumArtCache
        self.auth = auth
        self.openSettingsAction = openSettings
        self.selectedChannelId = initialChannelId
        self.persistChannelId = persistChannelId
    }

    func start() async {
        subscriptionTask?.cancel()
        subscriptionTask = nil
        do {
            self.channels = try await api.listChannels()
            self.errorMessage = nil
        } catch {
            self.errorMessage = "Failed to load channels: \(error.localizedDescription)"
        }

        if let snapshot = await coordinator.nowPlaying {
            self.nowPlaying = snapshot
            self.isPlaying = true
        }

        let stream = await coordinator.nowPlayingUpdates
        subscriptionTask = Task { [weak self] in
            for await np in stream {
                guard let self else { return }
                await MainActor.run {
                    self.nowPlaying = np
                    self.isPlaying = true
                    self.currentArt = nil
                    self.isSignedIn = self.auth.isLoggedIn
                    self.currentRating = Self.parseRating(from: np.song.userRating)
                }
                await self.loadArt(for: np)
            }
        }
    }

    func stop() async {
        subscriptionTask?.cancel()
        subscriptionTask = nil
    }

    func togglePlayPause() async {
        errorMessage = nil
        if isPlaying {
            do {
                try await coordinator.pause()
                isPlaying = false
            } catch {
                errorMessage = "Pause failed: \(error.localizedDescription)"
            }
        } else {
            do {
                try await coordinator.play(channelId: selectedChannelId)
                isPlaying = true
            } catch {
                errorMessage = "Playback failed: \(error.localizedDescription)"
            }
        }
    }

    func skipForward() async {
        errorMessage = nil
        do {
            try await coordinator.skipForward()
        } catch {
            errorMessage = "Skip failed: \(error.localizedDescription)"
        }
    }

    func selectChannel(_ id: Int) async {
        guard id != selectedChannelId else { return }
        errorMessage = nil
        let previous = selectedChannelId
        selectedChannelId = id
        inFlightChannelId = id
        do {
            try await coordinator.changeChannel(to: id)
            guard inFlightChannelId == id else { return }
            inFlightChannelId = nil
            await persistChannelId(id)
        } catch {
            guard inFlightChannelId == id else { return }
            inFlightChannelId = nil
            selectedChannelId = previous
            errorMessage = "Channel change failed: \(error.localizedDescription)"
        }
    }

    func rate(_ value: Int) async {
        guard isSignedIn,
              let np = nowPlaying,
              let songId = Int(np.song.songId)
        else { return }
        do {
            errorMessage = nil
            _ = try await api.rate(songId: songId, rating: value)
            currentRating = value
        } catch {
            errorMessage = "Rating failed: \(error.localizedDescription)"
        }
    }

    func openSettings() {
        openSettingsAction()
    }

    func refreshAuthState() {
        isSignedIn = auth.isLoggedIn
    }

    private static func parseRating(from raw: String?) -> Int? {
        guard let raw, let value = Int(raw) else { return nil }
        return (1...10).contains(value) ? value : nil
    }

    private func loadArt(for np: NowPlaying) async {
        guard let cover = np.song.cover else {
            await MainActor.run { self.currentArt = nil }
            return
        }
        let image = await albumArtCache.image(for: cover)
        await MainActor.run { self.currentArt = image }
    }
}

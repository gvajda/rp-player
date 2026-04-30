import Combine
import Foundation

@MainActor
final class MiniPlayerViewModel: ObservableObject {
    @Published private(set) var nowPlaying: NowPlaying?
    @Published private(set) var isPlaying: Bool = false
    @Published private(set) var channels: [Channel] = []
    @Published private(set) var selectedChannelId: Int
    @Published private(set) var errorMessage: String?

    typealias PersistChannelId = @Sendable (Int) async -> Void

    private let coordinator: any PlaybackCoordinator
    private let api: any RpApiClient
    private let persistChannelId: PersistChannelId
    private var subscriptionTask: Task<Void, Never>?

    init(
        coordinator: any PlaybackCoordinator,
        api: any RpApiClient,
        initialChannelId: Int,
        persistChannelId: @escaping PersistChannelId = { _ in }
    ) {
        self.coordinator = coordinator
        self.api = api
        self.selectedChannelId = initialChannelId
        self.persistChannelId = persistChannelId
    }

    func start() async {
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
                }
            }
        }
    }

    func stop() async {
        subscriptionTask?.cancel()
        subscriptionTask = nil
    }

    func togglePlayPause() async {
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
        do {
            try await coordinator.skipForward()
        } catch {
            errorMessage = "Skip failed: \(error.localizedDescription)"
        }
    }

    func selectChannel(_ id: Int) async {
        guard id != selectedChannelId else { return }
        let previous = selectedChannelId
        selectedChannelId = id
        do {
            try await coordinator.changeChannel(to: id)
            await persistChannelId(id)
        } catch {
            selectedChannelId = previous
            errorMessage = "Channel change failed: \(error.localizedDescription)"
        }
    }

    func setIsPlayingForTesting(_ value: Bool) {
        isPlaying = value
    }
}

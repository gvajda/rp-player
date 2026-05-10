import AppKit
import Combine
import Foundation
import SwiftUI

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
    @Published private(set) var currentBitrateLabel: String?
    @Published private(set) var songElapsedSeconds: Double = 0
    @Published private(set) var songDurationSeconds: Double = 0
    @Published private(set) var ambientTopColor: Color?
    @Published private(set) var popoverFloatingEnabled: Bool = false
    @Published private(set) var popoverStyle: PopoverStyle = .none
    @Published private(set) var updateButtonVisible: Bool = false
    @Published private(set) var updateAvailableForMenu: ReleaseInfo?
    private var ambientEnabled: Bool = false

    typealias PersistChannelId = @Sendable (Int) async -> Void

    private let coordinator: any PlaybackCoordinator
    private let api: any RpApiClient
    private let albumArtCache: any AlbumArtCache
    private let auth: any KeychainAuth
    private let configStore: any ConfigStore
    private let paletteExtractor: any AmbientPaletteExtracting
    private let openSettingsAction: @MainActor () -> Void
    private let persistChannelId: PersistChannelId
    private let updateChecker: any UpdateChecking
    private var subscriptionTask: Task<Void, Never>?
    private var positionSubscriptionTask: Task<Void, Never>?
    private var errorsSubscriptionTask: Task<Void, Never>?
    private var stateSubscriptionTask: Task<Void, Never>?
    private var settingsSubscriptionTask: Task<Void, Never>?
    private var updateStateTask: Task<Void, Never>?
    private var paletteTask: Task<Void, Never>?
    private var inFlightChannelId: Int?
    private var lastLoadedCoverPath: String?
    private var lastNotifiedSongId: String = ""
    private var hasStarted = false

    var remainingSecondsForTooltip: Int? {
        guard nowPlaying != nil, songDurationSeconds > 0 else { return nil }
        let remaining = songDurationSeconds - songElapsedSeconds
        return max(0, Int(remaining.rounded()))
    }

    var showPopoverIfNeeded: @MainActor () -> Void = {}
    var upcomingAction: @MainActor () -> Void = {}
    var openUpdatePanel: @MainActor () -> Void = {}

    init(
        coordinator: any PlaybackCoordinator,
        api: any RpApiClient,
        initialChannelId: Int,
        albumArtCache: any AlbumArtCache,
        auth: any KeychainAuth,
        configStore: any ConfigStore,
        paletteExtractor: any AmbientPaletteExtracting,
        openSettings: @escaping @MainActor () -> Void,
        persistChannelId: @escaping PersistChannelId = { _ in },
        updateChecker: any UpdateChecking = NoopUpdateChecker()
    ) {
        self.coordinator = coordinator
        self.api = api
        self.albumArtCache = albumArtCache
        self.auth = auth
        self.configStore = configStore
        self.paletteExtractor = paletteExtractor
        self.openSettingsAction = openSettings
        self.selectedChannelId = initialChannelId
        self.persistChannelId = persistChannelId
        self.updateChecker = updateChecker
    }

    func start() async {
        if hasStarted { return }
        hasStarted = true
        subscriptionTask?.cancel()
        subscriptionTask = nil
        positionSubscriptionTask?.cancel()
        positionSubscriptionTask = nil
        errorsSubscriptionTask?.cancel()
        errorsSubscriptionTask = nil
        stateSubscriptionTask?.cancel()
        stateSubscriptionTask = nil
        settingsSubscriptionTask?.cancel()
        settingsSubscriptionTask = nil
        paletteTask?.cancel()
        paletteTask = nil
        self.ambientEnabled = await configStore.settings.ambientBackgroundEnabled
        self.popoverFloatingEnabled = await configStore.settings.popoverFloating
        self.popoverStyle = await configStore.settings.popoverStyle
        do {
            self.channels = try await api.listChannels()
            self.errorMessage = nil
        } catch {
            self.errorMessage = "Failed to load channels: \(error.localizedDescription)"
        }

        if let snapshot = await coordinator.nowPlaying {
            self.nowPlaying = snapshot
            self.isPlaying = await coordinator.currentPlaybackState == .playing
        }

        let stream = await coordinator.nowPlayingUpdates
        subscriptionTask = Task { [weak self] in
            for await np in stream {
                guard let self else { return }
                let coverChanged = await MainActor.run { () -> Bool in
                    self.nowPlaying = np
                    self.isSignedIn = self.auth.isLoggedIn
                    self.currentRating = Self.parseRating(from: np.song.userRating)
                    self.currentBitrateLabel = BlockBitrateLabel.display(np.bitrateLabel)
                    let newDuration = np.songDurationSeconds
                    if np.song.songId != self.lastNotifiedSongId {
                        self.lastNotifiedSongId = np.song.songId
                        self.songElapsedSeconds = 0
                    }
                    self.songDurationSeconds = newDuration
                    if np.song.songId == "0" {
                        self.ambientTopColor = nil
                    }
                    let newCover = np.song.cover
                    if newCover != self.lastLoadedCoverPath {
                        self.lastLoadedCoverPath = newCover
                        self.currentArt = nil
                        return true
                    }
                    return false
                }
                if coverChanged {
                    await self.loadArt(for: np)
                }
            }
        }

        let positionStream = await coordinator.positionUpdates
        positionSubscriptionTask = Task { [weak self] in
            for await pos in positionStream {
                guard let self else { return }
                guard let np = self.nowPlaying else { continue }
                let duration = np.songDurationSeconds
                let elapsed = max(0, pos)
                self.songElapsedSeconds = min(elapsed, duration)
                self.songDurationSeconds = duration
            }
        }

        let errorsStream = await coordinator.errors
        errorsSubscriptionTask = Task { [weak self] in
            for await message in errorsStream {
                guard let self else { return }
                self.errorMessage = message
                self.isPlaying = false
                self.nowPlaying = nil
                self.ambientTopColor = nil
                self.showPopoverIfNeeded()
            }
        }

        let stateStream = await coordinator.stateUpdates
        stateSubscriptionTask = Task { [weak self] in
            for await state in stateStream {
                guard let self else { return }
                switch state {
                case .playing: isPlaying = true
                case .paused, .stopped: isPlaying = false
                }
            }
        }

        let settingsStream = await configStore.changes
        settingsSubscriptionTask = Task { [weak self] in
            for await snapshot in settingsStream {
                guard let self else { return }
                let wasEnabled = self.ambientEnabled
                self.ambientEnabled = snapshot.ambientBackgroundEnabled
                self.popoverFloatingEnabled = snapshot.popoverFloating
                self.popoverStyle = snapshot.popoverStyle
                if wasEnabled, !snapshot.ambientBackgroundEnabled {
                    self.ambientTopColor = nil
                } else if !wasEnabled, snapshot.ambientBackgroundEnabled,
                          let image = self.currentArt,
                          let cover = self.lastLoadedCoverPath {
                    self.extractPalette(from: image, coverPath: cover)
                }
            }
        }

        let updateStream = await updateChecker.stateUpdates
        updateStateTask = Task { [weak self] in
            for await state in updateStream {
                guard let self else { return }
                if Task.isCancelled { return }
                await MainActor.run { self.applyUpdateState(state) }
            }
        }
    }

    func togglePopoverFloating() {
        let store = configStore
        Task {
            try? await store.update { $0.popoverFloating.toggle() }
        }
    }

    func stop() async {
        subscriptionTask?.cancel(); subscriptionTask = nil
        positionSubscriptionTask?.cancel(); positionSubscriptionTask = nil
        errorsSubscriptionTask?.cancel(); errorsSubscriptionTask = nil
        stateSubscriptionTask?.cancel(); stateSubscriptionTask = nil
        settingsSubscriptionTask?.cancel(); settingsSubscriptionTask = nil
        paletteTask?.cancel(); paletteTask = nil
        updateStateTask?.cancel(); updateStateTask = nil
        hasStarted = false
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
        } else if nowPlaying != nil {
            // Engine still has the previous block loaded — resume rather than
            // re-fetch a new block, which would race with libmpv's audio device
            // state and silently produce no sound.
            do {
                try await coordinator.resume()
                isPlaying = true
            } catch {
                errorMessage = "Playback failed: \(error.localizedDescription)"
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
        // Skip the no-op only when the channel is already selected AND playback
        // is active. With nothing playing (stopped / error), clicking the same
        // channel should still start it — otherwise the Upcoming panel feels
        // dead when the user picks the channel they last had.
        if id == selectedChannelId && nowPlaying != nil { return }
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
        } catch RpApiError.invalidResponse(statusCode: 401, _) {
            // Stored cookie no longer accepted by RP — clear it and prompt re-login.
            await auth.clearCookie()
            isSignedIn = auth.isLoggedIn
            errorMessage = "Logged out — sign in again to rate."
        } catch {
            errorMessage = "Rating failed: \(error.localizedDescription)"
        }
    }

    func openSettings() {
        openSettingsAction()
    }

    func openCurrentSongInBrowser() {
        guard let np = nowPlaying,
              let id = Int(np.song.songId), id > 0,
              let url = URL(string: "https://radioparadise.com/music/song/\(id)") else { return }
        NSWorkspace.shared.open(url)
    }

    func openAbout() {
        NSWorkspace.shared.open(URL(string: "https://github.com/gvajda/rp-player")!)
    }

    func openUpcoming() {
        upcomingAction()
    }

    func applyUpdateState(_ state: UpdateState) {
        switch state {
        case .unknown, .upToDate:
            updateButtonVisible = false
            updateAvailableForMenu = nil
        case .available(let info, let dismissedFromButton):
            updateButtonVisible = !dismissedFromButton
            updateAvailableForMenu = info
        }
    }

    func requestOpenUpdatePanel() async {
        openUpdatePanel()
        await updateChecker.dismissCurrentForButton()
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
        await MainActor.run {
            self.currentArt = image
        }
        guard let image, ambientEnabled else { return }
        extractPalette(from: image, coverPath: cover)
    }

    private func extractPalette(from image: NSImage, coverPath: String) {
        paletteTask?.cancel()
        paletteTask = Task { [weak self, paletteExtractor] in
            let extracted = await paletteExtractor.extractBottomEdgeColor(from: image)
            guard let self else { return }
            await MainActor.run {
                guard self.lastLoadedCoverPath == coverPath else { return }
                self.ambientTopColor = extracted?.swiftUIColor
            }
        }
    }
}

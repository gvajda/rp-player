import AppKit
import Foundation
import SwiftUI

@MainActor
final class PastSongViewModel: ObservableObject {
    let song: PlayListSong
    @Published private(set) var currentArt: NSImage?
    @Published private(set) var currentRating: Int?
    @Published private(set) var isSignedIn: Bool
    @Published private(set) var ambientTopColor: Color?

    private let albumArtCache: any AlbumArtCache
    private let auth: any KeychainAuth
    private let api: any RpApiClient
    private let configStore: any ConfigStore
    private let paletteExtractor: any AmbientPaletteExtracting
    private var ambientEnabled: Bool = false
    private var paletteTask: Task<Void, Never>?
    private var settingsSubscriptionTask: Task<Void, Never>?

    init(
        song: PlayListSong,
        albumArtCache: any AlbumArtCache,
        auth: any KeychainAuth,
        api: any RpApiClient,
        configStore: any ConfigStore,
        paletteExtractor: any AmbientPaletteExtracting
    ) {
        self.song = song
        self.albumArtCache = albumArtCache
        self.auth = auth
        self.api = api
        self.configStore = configStore
        self.paletteExtractor = paletteExtractor
        self.currentRating = Self.parseRating(song.userRating)
        self.isSignedIn = auth.isLoggedIn
    }

    func start() async {
        isSignedIn = auth.isLoggedIn
        currentRating = Self.parseRating(song.userRating)
        ambientEnabled = await configStore.settings.ambientBackgroundEnabled

        let stream = await configStore.changes
        settingsSubscriptionTask?.cancel()
        settingsSubscriptionTask = Task { [weak self] in
            for await snapshot in stream {
                guard let self else { return }
                let was = self.ambientEnabled
                self.ambientEnabled = snapshot.ambientBackgroundEnabled
                if was, !snapshot.ambientBackgroundEnabled {
                    self.ambientTopColor = nil
                } else if !was, snapshot.ambientBackgroundEnabled, let image = self.currentArt {
                    self.extractPalette(from: image)
                }
            }
        }

        guard let cover = song.cover else { return }
        let image = await albumArtCache.image(for: cover)
        currentArt = image
        guard song.songId != "0" else {
            ambientTopColor = nil
            return
        }
        if let image, ambientEnabled {
            extractPalette(from: image)
        }
    }

    func stop() {
        settingsSubscriptionTask?.cancel(); settingsSubscriptionTask = nil
        paletteTask?.cancel(); paletteTask = nil
    }

    func rate(_ value: Int) async {
        guard let id = Int(song.songId) else { return }
        do {
            _ = try await api.rate(songId: id, rating: value)
            currentRating = value
        } catch {
            // Leave currentRating unchanged. No error UI in this minimal view.
        }
    }

    private func extractPalette(from image: NSImage) {
        paletteTask?.cancel()
        paletteTask = Task { [weak self, paletteExtractor] in
            let extracted = await paletteExtractor.extractBottomEdgeColor(from: image)
            guard let self else { return }
            await MainActor.run {
                self.ambientTopColor = extracted?.swiftUIColor
            }
        }
    }

    private static func parseRating(_ raw: String?) -> Int? {
        guard let raw, let value = Int(raw), (1...10).contains(value) else { return nil }
        return value
    }
}

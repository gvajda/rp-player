import AppKit
import Foundation

@MainActor
public final class PastSongViewModel: ObservableObject {
    public let song: PlayListSong
    @Published public private(set) var currentArt: NSImage?
    @Published public private(set) var currentRating: Int?
    @Published public private(set) var isSignedIn: Bool

    private let albumArtCache: any AlbumArtCache
    private let auth: any KeychainAuth
    private let api: any RpApiClient

    public init(
        song: PlayListSong,
        albumArtCache: any AlbumArtCache,
        auth: any KeychainAuth,
        api: any RpApiClient
    ) {
        self.song = song
        self.albumArtCache = albumArtCache
        self.auth = auth
        self.api = api
        self.currentRating = Self.parseRating(song.userRating)
        self.isSignedIn = auth.isLoggedIn
    }

    public func start() async {
        isSignedIn = auth.isLoggedIn
        currentRating = Self.parseRating(song.userRating)
        guard let cover = song.cover else { return }
        let image = await albumArtCache.image(for: cover)
        currentArt = image
    }

    public func rate(_ value: Int) async {
        guard let id = Int(song.songId) else { return }
        do {
            _ = try await api.rate(songId: id, rating: value)
            currentRating = value
        } catch {
            // Leave currentRating unchanged. No error UI in this minimal view.
        }
    }

    private static func parseRating(_ raw: String?) -> Int? {
        guard let raw, let value = Int(raw), (1...10).contains(value) else { return nil }
        return value
    }
}

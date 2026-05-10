import AppKit
import SwiftUI

struct UpcomingColumn: Identifiable, Sendable {
    let id: Int
    let channel: Channel
    let songs: [UpcomingSongRow]
}

struct UpcomingSongRow: Identifiable, Sendable {
    let id: String
    let song: GaplessSong
    let art: NSImage?
    let ambientColor: Color
}

@MainActor
final class UpcomingProgramViewModel: ObservableObject {
    @Published private(set) var columns: [UpcomingColumn] = []
    @Published private(set) var isLoading = false
    @Published private(set) var lastUpdated: Date?
    @Published private(set) var errorMessage: String?
    @Published private(set) var skeletonColumnCount: Int = 4
    @Published private(set) var currentChannelId: Int?
    @Published private(set) var currentSongId: String?

    private let api: any RpApiClient
    private let albumArtCache: any AlbumArtCache
    private let configStore: any ConfigStore
    private let paletteExtractor: any AmbientPaletteExtracting
    private let coordinator: (any PlaybackCoordinator)?
    private let selectChannelHandler: (@MainActor (Int) async -> Void)?
    private var nowPlayingTask: Task<Void, Never>?
    private var cachedChannels: [Channel] = []

    /// Per-column UI metrics — kept in lock-step with `UpcomingProgramView`.
    /// Used by `UpcomingWindowController` to compute the snug window width.
    /// Each column renders as a 226pt frame wrapped in `.padding(6)` (so the
    /// column card occupies 238pt total), separated by a 6pt HStack spacing,
    /// inside an HStack with `.padding(10)`.
    static let columnWidth: CGFloat = 226
    static let columnOuterPadding: CGFloat = 6  // .padding(6) on each column card
    static let columnSpacing: CGFloat = 6
    static let columnsContainerPadding: CGFloat = 10  // .padding(10) on the HStack

    init(
        api: any RpApiClient,
        albumArtCache: any AlbumArtCache,
        configStore: any ConfigStore,
        paletteExtractor: any AmbientPaletteExtracting,
        coordinator: (any PlaybackCoordinator)? = nil,
        selectChannelHandler: (@MainActor (Int) async -> Void)? = nil
    ) {
        self.api = api
        self.albumArtCache = albumArtCache
        self.configStore = configStore
        self.paletteExtractor = paletteExtractor
        self.coordinator = coordinator
        self.selectChannelHandler = selectChannelHandler
    }

    deinit { nowPlayingTask?.cancel() }

    private func ensureNowPlayingSubscription() async {
        guard nowPlayingTask == nil, let coordinator else { return }
        if let snapshot = await coordinator.nowPlaying {
            currentChannelId = snapshot.channelId
            currentSongId = snapshot.song.songId
        }
        let stream = await coordinator.nowPlayingUpdates
        nowPlayingTask = Task { [weak self] in
            for await np in stream {
                guard let self else { return }
                self.currentChannelId = np.channelId
                self.currentSongId = np.song.songId
            }
        }
    }

    func selectChannel(_ id: Int) {
        guard let handler = selectChannelHandler else { return }
        Task { await handler(id) }
    }

    /// Width of the columns-container content needed to fit the currently
    /// configured (filtered) channel list. Lazily primes the channel cache
    /// via `api.listChannels()` if `load()` hasn't run yet — required for the
    /// window-pre-flight resize to work on the first show after app restart.
    /// Returns nil only when the channel list is unavailable.
    func desiredContentWidth() async -> CGFloat? {
        if cachedChannels.isEmpty {
            cachedChannels = (try? await api.listChannels()) ?? []
        }
        guard !cachedChannels.isEmpty else { return nil }
        let settings = await configStore.settings
        let hiddenIds = Set(settings.upcomingHiddenChannelIds)
        let count = cachedChannels.filter {
            guard let id = Int($0.chan) else { return false }
            return id != 42 && id != 99 && !hiddenIds.contains(id)
        }.count
        guard count > 0 else { return nil }
        let n = CGFloat(count)
        let perColumn = Self.columnWidth + 2 * Self.columnOuterPadding
        return n * perColumn + (n - 1) * Self.columnSpacing + 2 * Self.columnsContainerPadding
    }

    func load() async {
        await ensureNowPlayingSubscription()
        isLoading = true
        errorMessage = nil

        let settings = await configStore.settings
        let rowCount = settings.upcomingRowCount
        let hiddenIds = Set(settings.upcomingHiddenChannelIds)
        let bitrate = settings.bitrate

        let allChannels: [Channel]
        do {
            allChannels = try await api.listChannels()
        } catch {
            errorMessage = "Failed to load channels."
            isLoading = false
            return
        }
        cachedChannels = allChannels

        let enabledChannels = allChannels.filter {
            guard let id = Int($0.chan) else { return false }
            return id != 42 && id != 99 && !hiddenIds.contains(id)
        }

        skeletonColumnCount = enabledChannels.count

        // Single api/gapless call per channel. Filter promos inline.
        let api = self.api
        let fetchCount = max(rowCount * 2, rowCount + 5)  // overshoot to absorb promo filtering
        var rowResults: [(Int, Channel, [GaplessSong])] = []
        await withTaskGroup(of: (Int, Channel, [GaplessSong]).self) { group in
            for (i, channel) in enabledChannels.enumerated() {
                guard let chanId = Int(channel.chan) else { continue }
                group.addTask {
                    let response = try? await api.gapless(channel: chanId, bitrate: bitrate, numSongs: fetchCount)
                    let visible = (response?.songs ?? []).filter { $0.type != "P" && $0.songId != "0" }
                    return (i, channel, Array(visible.prefix(rowCount)))
                }
            }
            for await result in group {
                rowResults.append(result)
            }
        }
        rowResults.sort { $0.0 < $1.0 }

        if rowResults.contains(where: { $0.2.isEmpty }) {
            errorMessage = "Some channels could not be loaded."
        }

        struct ColStub {
            let channel: Channel
            let chanId: Int
            let songs: [GaplessSong]
        }

        let stubs: [ColStub] = rowResults.compactMap { _, channel, songs in
            guard let chanId = Int(channel.chan) else { return nil }
            return ColStub(channel: channel, chanId: chanId, songs: songs)
        }

        // Collect art + palette results keyed by (colIndex, rowIndex).
        let albumArtCache = self.albumArtCache
        let paletteExtractor = self.paletteExtractor
        var artResults: [String: (NSImage?, Color)] = [:]
        await withTaskGroup(of: (String, NSImage?, Color).self) { group in
            for (ci, stub) in stubs.enumerated() {
                for (ri, song) in stub.songs.enumerated() {
                    let cover = song.coverLarge ?? song.coverMedium
                    guard let cover, !cover.isEmpty else { continue }
                    let key = "\(ci)-\(ri)"
                    group.addTask {
                        let image = await albumArtCache.image(for: cover)
                        var color = Color(nsColor: .windowBackgroundColor)
                        if let img = image,
                           let extracted = await paletteExtractor.extractBottomEdgeColor(from: img) {
                            color = extracted.swiftUIColor
                        }
                        return (key, image, color)
                    }
                }
            }
            for await (key, image, color) in group {
                artResults[key] = (image, color)
            }
        }

        columns = stubs.enumerated().map { ci, stub in
            let rows = stub.songs.enumerated().map { ri, song in
                let (art, color) = artResults["\(ci)-\(ri)"] ?? (nil, Color(nsColor: .windowBackgroundColor))
                return UpcomingSongRow(id: "\(stub.chanId)-\(song.songId)", song: song, art: art, ambientColor: color)
            }
            return UpcomingColumn(id: stub.chanId, channel: stub.channel, songs: rows)
        }
        isLoading = false
        lastUpdated = Date()
    }

    func refresh() async {
        await load()
    }
}

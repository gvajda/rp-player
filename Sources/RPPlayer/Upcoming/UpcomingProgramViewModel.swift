import AppKit
import SwiftUI

struct UpcomingColumn: Identifiable, Sendable {
    let id: Int
    let channel: Channel
    let songs: [UpcomingSongRow]
}

struct UpcomingSongRow: Identifiable, Sendable {
    let id: String
    let song: PlayListSong
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

        let enabledChannels = allChannels.filter {
            guard let id = Int($0.chan) else { return false }
            return id != 42 && id != 99 && !hiddenIds.contains(id)
        }

        skeletonColumnCount = enabledChannels.count

        // Fetch blocks concurrently, accumulating across multiple blocks until rowCount is met.
        // Uses api/play (the same endpoint the live coordinator uses) so the
        // upcoming list matches what will actually play. First call per channel
        // bootstraps with event=0 / action=start; subsequent calls advance with
        // action=play + the last song's audio_type and slice_num.
        let api = self.api
        var rowResults: [(Int, Channel, [PlayListSong])] = []
        await withTaskGroup(of: (Int, Channel, [PlayListSong]).self) { group in
            for (i, channel) in enabledChannels.enumerated() {
                guard let chanId = Int(channel.chan) else { continue }
                group.addTask {
                    var songs: [PlayListSong] = []
                    var event = 0
                    var action: PlayAction = .start
                    var audioType: String? = nil
                    var sliceNum: String? = nil
                    var episodeId: Int? = nil
                    while songs.count < rowCount {
                        guard let block = try? await api.play(
                            channel: chanId, bitrate: bitrate, event: event,
                            action: action, audioType: audioType,
                            episodeId: episodeId, sliceNum: sliceNum
                        ) else { break }
                        let blockSongs = BlockSongs.orderedSongs(from: block)
                        let visible = blockSongs
                            .filter { $0.type != "P" && $0.songId != "0" }
                        songs.append(contentsOf: visible)
                        guard let endEventStr = block.endEvent,
                              let nextEvent = Int(endEventStr),
                              nextEvent != event,
                              songs.count < rowCount,
                              let lastSong = blockSongs.last else { break }
                        event = nextEvent
                        action = .play
                        audioType = lastSong.type ?? "M"
                        sliceNum = lastSong.sliceNum
                        episodeId = 0
                    }
                    return (i, channel, Array(songs.prefix(rowCount)))
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
            let songs: [PlayListSong]
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
                    guard let cover = song.cover, !cover.isEmpty else { continue }
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

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
    var art: NSImage?
    var ambientColor: Color = Color(nsColor: .windowBackgroundColor)
}

@MainActor
final class UpcomingProgramViewModel: ObservableObject {
    @Published private(set) var columns: [UpcomingColumn] = []
    @Published private(set) var isLoading = false
    @Published private(set) var lastUpdated: Date?
    @Published private(set) var errorMessage: String?

    private let api: any RpApiClient
    private let albumArtCache: any AlbumArtCache
    private let configStore: any ConfigStore
    private let paletteExtractor: any AmbientPaletteExtracting

    init(
        api: any RpApiClient,
        albumArtCache: any AlbumArtCache,
        configStore: any ConfigStore,
        paletteExtractor: any AmbientPaletteExtracting
    ) {
        self.api = api
        self.albumArtCache = albumArtCache
        self.configStore = configStore
        self.paletteExtractor = paletteExtractor
    }

    func load() async {
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

        // Fetch all blocks concurrently, preserving channel order.
        let api = self.api
        var blockResults: [(Int, Channel, GetBlock?)] = []
        await withTaskGroup(of: (Int, Channel, GetBlock?).self) { group in
            for (i, channel) in enabledChannels.enumerated() {
                guard let chanId = Int(channel.chan) else { continue }
                group.addTask {
                    let block = try? await api.getBlock(channel: chanId, bitrate: bitrate)
                    return (i, channel, block)
                }
            }
            for await result in group {
                blockResults.append(result)
            }
        }
        blockResults.sort { $0.0 < $1.0 }

        if blockResults.contains(where: { $0.2 == nil }) {
            errorMessage = "Some channels could not be loaded."
        }

        struct ColStub {
            let channel: Channel
            var rows: [UpcomingSongRow]
        }

        var stubs: [ColStub] = blockResults.map { _, channel, block in
            guard let block else { return ColStub(channel: channel, rows: []) }
            let songs = Array(BlockSongs.orderedSongs(from: block).prefix(rowCount))
            let rows = songs.map { UpcomingSongRow(id: $0.songId, song: $0) }
            return ColStub(channel: channel, rows: rows)
        }

        // Load art + ambient palette for every row concurrently.
        let albumArtCache = self.albumArtCache
        let paletteExtractor = self.paletteExtractor
        await withTaskGroup(of: (Int, Int, NSImage?, Color).self) { group in
            for (ci, stub) in stubs.enumerated() {
                for (ri, row) in stub.rows.enumerated() {
                    guard let cover = row.song.cover, !cover.isEmpty else { continue }
                    group.addTask {
                        let image = await albumArtCache.image(for: cover)
                        var color = Color(nsColor: .windowBackgroundColor)
                        if let img = image,
                           let extracted = await paletteExtractor.extractBottomEdgeColor(from: img) {
                            color = extracted.swiftUIColor
                        }
                        return (ci, ri, image, color)
                    }
                }
            }
            for await (ci, ri, image, color) in group {
                stubs[ci].rows[ri].art = image
                stubs[ci].rows[ri].ambientColor = color
            }
        }

        columns = stubs.compactMap { stub in
            guard let id = Int(stub.channel.chan) else { return nil }
            return UpcomingColumn(id: id, channel: stub.channel, songs: stub.rows)
        }
        isLoading = false
        lastUpdated = Date()
    }

    func refresh() {
        Task { await load() }
    }
}

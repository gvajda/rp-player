import AppKit
@testable import RPPlayer

@MainActor
final class StubAlbumArtCache: AlbumArtCache {
    var imageByPath: [String: NSImage] = [:]
    var requestedPaths: [String] = []
    func image(for coverPath: String) async -> NSImage? {
        await MainActor.run { self.requestedPaths.append(coverPath) }
        return await MainActor.run { self.imageByPath[coverPath] }
    }
}

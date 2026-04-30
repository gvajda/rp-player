import AppKit
import CryptoKit
import Foundation

public protocol AlbumArtCache: Sendable {
    func image(for coverPath: String) async -> NSImage?
    func fileURL(for coverPath: String) async -> URL?
}

public extension AlbumArtCache {
    func fileURL(for coverPath: String) async -> URL? { nil }
}

public actor LiveAlbumArtCache: AlbumArtCache {
    public static let defaultMaxFiles = 20
    public static let defaultMaxBytes = 10 * 1024 * 1024

    private let directory: URL
    private let baseURL: URL
    private let session: URLSession
    private let logger: any Logging
    private let maxFiles: Int
    private let maxBytes: Int
    private var inFlight: [String: Task<NSImage?, Never>] = [:]

    public init(
        directory: URL,
        baseURL: URL,
        session: URLSession = .shared,
        logger: any Logging,
        maxFiles: Int = LiveAlbumArtCache.defaultMaxFiles,
        maxBytes: Int = LiveAlbumArtCache.defaultMaxBytes
    ) throws {
        self.directory = directory
        self.baseURL = baseURL
        self.session = session
        self.logger = logger
        self.maxFiles = maxFiles
        self.maxBytes = maxBytes
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    public func image(for coverPath: String) async -> NSImage? {
        let key = Self.cacheKey(for: coverPath)
        let fileURL = directory.appendingPathComponent(key)

        if let image = Self.loadImage(at: fileURL) {
            try? FileManager.default.setAttributes(
                [.modificationDate: Date()], ofItemAtPath: fileURL.path
            )
            return image
        }

        if let existing = inFlight[coverPath] {
            return await existing.value
        }
        let task = Task { [weak self] () -> NSImage? in
            let result = await self?.downloadAndStore(coverPath: coverPath, fileURL: fileURL) ?? nil
            await self?.clearInFlight(coverPath: coverPath)
            return result
        }
        inFlight[coverPath] = task
        return await task.value
    }

    private func clearInFlight(coverPath: String) {
        inFlight[coverPath] = nil
    }

    public func fileURL(for coverPath: String) -> URL? {
        let key = Self.cacheKey(for: coverPath)
        let url = directory.appendingPathComponent(key)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    private func downloadAndStore(coverPath: String, fileURL: URL) async -> NSImage? {
        guard let url = URL(string: coverPath, relativeTo: baseURL)?.absoluteURL else {
            logger.error("Invalid cover URL for path: \(coverPath)")
            return nil
        }
        do {
            let (data, response) = try await session.data(from: url)
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                logger.error("Cover fetch failed: HTTP \((response as? HTTPURLResponse)?.statusCode ?? -1) for \(url.absoluteString)")
                return nil
            }
            guard !data.isEmpty, let image = NSImage(data: data) else {
                logger.error("Cover response was empty or not a valid image: \(url.absoluteString)")
                return nil
            }
            try data.write(to: fileURL, options: [.atomic])
            evictIfNeeded()
            return image
        } catch {
            logger.error("Cover fetch threw: \(error.localizedDescription) for \(url.absoluteString)")
            return nil
        }
    }

    private func evictIfNeeded() {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey],
            options: [.skipsHiddenFiles]
        ) else { return }

        var aged: [(URL, Date, Int)] = []
        for url in entries {
            do {
                let v = try url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
                guard let modDate = v.contentModificationDate, let size = v.fileSize else { continue }
                aged.append((url, modDate, size))
            } catch {
                logger.error("Album art eviction skipped \(url.lastPathComponent): \(error.localizedDescription)")
            }
        }
        aged.sort { $0.1 < $1.1 }

        var totalBytes = aged.reduce(0) { $0 + $1.2 }
        while aged.count > maxFiles || totalBytes > maxBytes, let oldest = aged.first {
            try? fm.removeItem(at: oldest.0)
            totalBytes -= oldest.2
            aged.removeFirst()
        }
    }

    private static func cacheKey(for coverPath: String) -> String {
        let digest = SHA256.hash(data: Data(coverPath.utf8))
        let hex = digest.map { String(format: "%02x", $0) }.joined()
        return hex + ".jpg"
    }

    private static func loadImage(at fileURL: URL) -> NSImage? {
        guard let data = try? Data(contentsOf: fileURL) else { return nil }
        return NSImage(data: data)
    }
}

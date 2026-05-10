import CryptoKit
import Foundation

public protocol SongFileCache: Sendable {
    func localFile(for song: GaplessSong) async -> URL?
    func cachedFile(for song: GaplessSong) -> URL?
    func evict(_ song: GaplessSong) async
    func clear() async
}

public actor LiveSongFileCache: SongFileCache {
    nonisolated private let directory: URL
    private let session: URLSession
    private let logger: any Logging
    private var inFlight: [String: Task<URL?, Never>] = [:]

    public init(
        directory: URL,
        session: URLSession = .shared,
        logger: any Logging
    ) throws {
        self.directory = directory
        self.session = session
        self.logger = logger
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    public func localFile(for song: GaplessSong) async -> URL? {
        let filename = Self.cacheFilename(for: song)
        let fileURL = directory.appendingPathComponent(filename)
        if FileManager.default.fileExists(atPath: fileURL.path) {
            try? FileManager.default.setAttributes(
                [.modificationDate: Date()], ofItemAtPath: fileURL.path
            )
            return fileURL
        }
        if let existing = inFlight[filename] {
            return await existing.value
        }
        let task = Task { [weak self] () -> URL? in
            let result = await self?.downloadAndStore(song: song, fileURL: fileURL) ?? nil
            await self?.clearInFlight(filename: filename)
            return result
        }
        inFlight[filename] = task
        return await task.value
    }

    public nonisolated func cachedFile(for song: GaplessSong) -> URL? {
        let filename = Self.cacheFilename(for: song)
        let fileURL = directory.appendingPathComponent(filename)
        return FileManager.default.fileExists(atPath: fileURL.path) ? fileURL : nil
    }

    public func evict(_ song: GaplessSong) {
        let filename = Self.cacheFilename(for: song)
        let fileURL = directory.appendingPathComponent(filename)
        try? FileManager.default.removeItem(at: fileURL)
    }

    public func clear() {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) else { return }
        for url in entries {
            try? fm.removeItem(at: url)
        }
    }

    private func clearInFlight(filename: String) {
        inFlight[filename] = nil
    }

    private func downloadAndStore(song: GaplessSong, fileURL: URL) async -> URL? {
        guard let url = URL(string: song.gaplessUrl) else {
            logger.error("SongFileCache: invalid gapless URL: \(song.gaplessUrl)")
            return nil
        }
        if Task.isCancelled { return nil }
        do {
            let (data, response) = try await session.data(from: url)
            // Skip disk write if cancelled mid-flight — avoids orphan files when the coordinator
            // tears down its downloaderTask between download start and completion.
            if Task.isCancelled { return nil }
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                logger.error("SongFileCache fetch failed: HTTP \((response as? HTTPURLResponse)?.statusCode ?? -1) for \(url.absoluteString)")
                return nil
            }
            guard !data.isEmpty else {
                logger.error("SongFileCache response was empty: \(url.absoluteString)")
                return nil
            }
            try data.write(to: fileURL, options: [.atomic])
            return fileURL
        } catch {
            logger.error("SongFileCache fetch threw: \(error.localizedDescription) for \(url.absoluteString)")
            return nil
        }
    }

    private nonisolated static func cacheFilename(for song: GaplessSong) -> String {
        let digest = SHA256.hash(data: Data(song.gaplessUrl.utf8))
        let hex = digest.map { String(format: "%02x", $0) }.joined()
        let parsedExt = URL(string: song.gaplessUrl)?.pathExtension ?? ""
        let ext = parsedExt.isEmpty ? "bin" : parsedExt
        return "\(hex).\(ext)"
    }
}

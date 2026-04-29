import Foundation

/// Append-only log file with size-based rotation. `Base.log` is the active
/// file; on overflow it becomes `Base.1.log` and the previous `Base.N.log`
/// files shift down. `Base.<maxFiles>.log` is dropped when full.
public final class RotatingFileSink {
    private let directory: URL
    private let baseName: String
    private let fileExtension: String
    private let maxFileBytes: Int
    private let maxFiles: Int
    private let queue = DispatchQueue(label: "com.gvajda.RPPlayer.RotatingFileSink")
    private var handle: FileHandle?

    public init(
        directory: URL,
        baseName: String = "RPPlayer",
        fileExtension: String = "log",
        maxFileBytes: Int = 1_048_576,
        maxFiles: Int = 10
    ) throws {
        self.directory = directory
        self.baseName = baseName
        self.fileExtension = fileExtension
        self.maxFileBytes = maxFileBytes
        self.maxFiles = maxFiles
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true
        )
        try openHandle()
    }

    public func writeLine(_ line: String) {
        queue.sync {
            let payload = (line + "\n").data(using: .utf8) ?? Data()
            do {
                try rotateIfNeeded(adding: payload.count)
                handle?.write(payload)
            } catch {
                // Disk full / IO error must not crash the app.
            }
        }
    }

    deinit {
        try? handle?.close()
    }

    private var currentURL: URL {
        directory.appendingPathComponent("\(baseName).\(fileExtension)")
    }

    private func archivedURL(_ index: Int) -> URL {
        directory.appendingPathComponent("\(baseName).\(index).\(fileExtension)")
    }

    private func openHandle() throws {
        let url = currentURL
        if !FileManager.default.fileExists(atPath: url.path) {
            FileManager.default.createFile(atPath: url.path, contents: nil)
        }
        handle = try FileHandle(forWritingTo: url)
        try handle?.seekToEnd()
    }

    private func rotateIfNeeded(adding bytes: Int) throws {
        let url = currentURL
        let size = (try FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0
        if size + bytes <= maxFileBytes { return }

        try handle?.close()
        handle = nil

        let fm = FileManager.default
        let oldest = archivedURL(maxFiles)
        if fm.fileExists(atPath: oldest.path) {
            try fm.removeItem(at: oldest)
        }
        for i in stride(from: maxFiles - 1, through: 1, by: -1) {
            let from = archivedURL(i)
            let to = archivedURL(i + 1)
            if fm.fileExists(atPath: from.path) {
                try fm.moveItem(at: from, to: to)
            }
        }
        try fm.moveItem(at: url, to: archivedURL(1))
        try openHandle()
    }
}

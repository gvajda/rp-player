import Foundation

public enum EqPresetStoreError: Error, Equatable, Sendable {
    case invalidName
    case alreadyExists
    case notFound
    case ioFailure(String)
}

public protocol EqPresetStore: Sendable {
    func list() async -> [String]
    func exists(name: String) async -> Bool
    func loadText(name: String) async throws -> String
    func save(name: String, text: String, overwrite: Bool) async throws
    func delete(name: String) async throws
    func rename(from: String, to: String) async throws
}

public actor LiveEqPresetStore: EqPresetStore {
    public let directory: URL
    private let fm = FileManager.default
    private let logger: (any Logging)?

    public init(directory: URL, logger: (any Logging)? = nil) {
        self.directory = directory
        self.logger = logger
        do {
            try fm.createDirectory(at: directory, withIntermediateDirectories: true)
            logger?.debug("EqPresetStore: directory ready at \(directory.path)")
        } catch {
            logger?.error("EqPresetStore: failed to create directory at \(directory.path): \(error)")
        }
    }

    public func list() async -> [String] {
        guard let entries = try? fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) else {
            return []
        }
        return entries
            .filter { $0.pathExtension.lowercased() == "txt" }
            .map { $0.deletingPathExtension().lastPathComponent }
            .sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
    }

    public func exists(name: String) async -> Bool {
        guard validate(name) else { return false }
        return fm.fileExists(atPath: fileURL(for: name).path)
    }

    public func loadText(name: String) async throws -> String {
        logger?.debug("EqPresetStore.loadText name=\(name)")
        guard validate(name) else {
            logger?.warn("EqPresetStore.loadText rejected name=\(name) reason=invalidName")
            throw EqPresetStoreError.invalidName
        }
        let url = fileURL(for: name)
        guard fm.fileExists(atPath: url.path) else {
            logger?.warn("EqPresetStore.loadText name=\(name) reason=notFound path=\(url.path)")
            throw EqPresetStoreError.notFound
        }
        do {
            let text = try String(contentsOf: url, encoding: .utf8)
            logger?.debug("EqPresetStore.loadText name=\(name) read=\(text.utf8.count) bytes")
            return text
        } catch {
            logger?.error("EqPresetStore.loadText name=\(name) ioFailure=\(error)")
            throw EqPresetStoreError.ioFailure("\(error)")
        }
    }

    public func save(name: String, text: String, overwrite: Bool) async throws {
        logger?.debug("EqPresetStore.save name=\(name) bytes=\(text.utf8.count) overwrite=\(overwrite)")
        guard validate(name) else {
            logger?.warn("EqPresetStore.save rejected name=\(name) reason=invalidName")
            throw EqPresetStoreError.invalidName
        }
        let url = fileURL(for: name)
        if fm.fileExists(atPath: url.path) && !overwrite {
            logger?.info("EqPresetStore.save name=\(name) skipped reason=alreadyExists")
            throw EqPresetStoreError.alreadyExists
        }
        do {
            try text.write(to: url, atomically: true, encoding: .utf8)
            logger?.info("EqPresetStore.save name=\(name) wrote=\(url.path)")
        } catch {
            logger?.error("EqPresetStore.save name=\(name) ioFailure=\(error)")
            throw EqPresetStoreError.ioFailure("\(error)")
        }
    }

    public func delete(name: String) async throws {
        logger?.debug("EqPresetStore.delete name=\(name)")
        guard validate(name) else {
            logger?.warn("EqPresetStore.delete rejected name=\(name) reason=invalidName")
            throw EqPresetStoreError.invalidName
        }
        let url = fileURL(for: name)
        guard fm.fileExists(atPath: url.path) else {
            logger?.warn("EqPresetStore.delete name=\(name) reason=notFound")
            throw EqPresetStoreError.notFound
        }
        do {
            try fm.removeItem(at: url)
            logger?.info("EqPresetStore.delete name=\(name) removed=\(url.path)")
        } catch {
            logger?.error("EqPresetStore.delete name=\(name) ioFailure=\(error)")
            throw EqPresetStoreError.ioFailure("\(error)")
        }
    }

    public func rename(from: String, to: String) async throws {
        logger?.debug("EqPresetStore.rename from=\(from) to=\(to)")
        guard validate(from) else {
            logger?.warn("EqPresetStore.rename rejected from=\(from) reason=invalidName")
            throw EqPresetStoreError.invalidName
        }
        guard validate(to) else {
            logger?.warn("EqPresetStore.rename rejected to=\(to) reason=invalidName")
            throw EqPresetStoreError.invalidName
        }
        let src = fileURL(for: from)
        let dst = fileURL(for: to)
        guard fm.fileExists(atPath: src.path) else {
            logger?.warn("EqPresetStore.rename from=\(from) reason=notFound")
            throw EqPresetStoreError.notFound
        }
        if from == to { return }
        if fm.fileExists(atPath: dst.path) {
            logger?.info("EqPresetStore.rename to=\(to) skipped reason=alreadyExists")
            throw EqPresetStoreError.alreadyExists
        }
        do {
            try fm.moveItem(at: src, to: dst)
            logger?.info("EqPresetStore.rename from=\(from) to=\(to) moved")
        } catch {
            logger?.error("EqPresetStore.rename ioFailure=\(error)")
            throw EqPresetStoreError.ioFailure("\(error)")
        }
    }

    private func fileURL(for name: String) -> URL {
        directory.appendingPathComponent("\(name).txt", isDirectory: false)
    }

    private func validate(_ name: String) -> Bool {
        guard !name.isEmpty, name.count <= 30 else { return false }
        if name.hasPrefix(".") { return false }
        if name.contains("/") || name.contains("\0") { return false }
        return true
    }
}

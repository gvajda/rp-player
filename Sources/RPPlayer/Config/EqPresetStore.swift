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
}

public actor LiveEqPresetStore: EqPresetStore {
    public let directory: URL
    private let fm = FileManager.default

    public init(directory: URL) {
        self.directory = directory
        try? fm.createDirectory(at: directory, withIntermediateDirectories: true)
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
        guard validate(name) else { throw EqPresetStoreError.invalidName }
        let url = fileURL(for: name)
        guard fm.fileExists(atPath: url.path) else { throw EqPresetStoreError.notFound }
        do { return try String(contentsOf: url, encoding: .utf8) }
        catch { throw EqPresetStoreError.ioFailure("\(error)") }
    }

    public func save(name: String, text: String, overwrite: Bool) async throws {
        guard validate(name) else { throw EqPresetStoreError.invalidName }
        let url = fileURL(for: name)
        if fm.fileExists(atPath: url.path) && !overwrite {
            throw EqPresetStoreError.alreadyExists
        }
        do { try text.write(to: url, atomically: true, encoding: .utf8) }
        catch { throw EqPresetStoreError.ioFailure("\(error)") }
    }

    public func delete(name: String) async throws {
        guard validate(name) else { throw EqPresetStoreError.invalidName }
        let url = fileURL(for: name)
        guard fm.fileExists(atPath: url.path) else { throw EqPresetStoreError.notFound }
        do { try fm.removeItem(at: url) }
        catch { throw EqPresetStoreError.ioFailure("\(error)") }
    }

    private func fileURL(for name: String) -> URL {
        directory.appendingPathComponent("\(name).txt", isDirectory: false)
    }

    private func validate(_ name: String) -> Bool {
        guard !name.isEmpty, name.count < 256 else { return false }
        if name.hasPrefix(".") { return false }
        if name.contains("/") || name.contains("\0") { return false }
        return true
    }
}

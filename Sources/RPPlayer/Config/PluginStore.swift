import Foundation

public actor PluginStore {
    public static let bundleArchitectures: @Sendable (URL) -> [Int] = { url in
        Bundle(url: url)?.executableArchitectures?.map(\.intValue) ?? []
    }

    public let directory: URL
    private let fm = FileManager.default
    private let logger: (any Logging)?
    private let architectures: @Sendable (URL) -> [Int]

    public init(directory: URL, logger: (any Logging)? = nil,
                architectures: @escaping @Sendable (URL) -> [Int] = PluginStore.bundleArchitectures) {
        self.directory = directory
        self.logger = logger
        self.architectures = architectures
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        } catch {
            logger?.error("PluginStore: failed to create \(directory.path): \(error)")
        }
    }

    public func list() -> [ImportedPlugin] {
        let names = (try? fm.contentsOfDirectory(atPath: directory.path)) ?? []
        return names.compactMap { plugin(id: $0) }
            .sorted { $0.component.name.localizedCaseInsensitiveCompare($1.component.name) == .orderedAscending }
    }

    public func plugin(id: String) -> ImportedPlugin? {
        guard let folder = folder(for: id),
              let bundleName = (try? fm.contentsOfDirectory(atPath: folder.path))?.first(where: { $0.hasSuffix(".component") }) else {
            return nil
        }
        let bundleURL = folder.appendingPathComponent(bundleName)
        guard case .success(let component) = PluginValidator.validate(
            infoPlist: Self.infoPlist(of: bundleURL), architectures: [PluginValidator.hostArchitecture], existing: []) else {
            return nil
        }
        return ImportedPlugin(id: id, bundleURL: bundleURL, component: component)
    }

    public func importComponent(from source: URL) throws -> ImportedPlugin {
        let resolved = source.resolvingSymlinksInPath()
        let component = try PluginValidator.validate(
            infoPlist: Self.infoPlist(of: resolved), architectures: architectures(resolved),
            existing: list().map(\.component)).get()
        let id = UUID().uuidString
        let name = source.lastPathComponent
        // Staging names are not UUIDs, so list() never shows a half-copied import.
        let staging = directory.appendingPathComponent(".staging-\(id)")
        do {
            try fm.createDirectory(at: staging, withIntermediateDirectories: true)
            try fm.copyItem(at: resolved, to: staging.appendingPathComponent(name))
            try fm.moveItem(at: staging, to: directory.appendingPathComponent(id))
        } catch {
            try? fm.removeItem(at: staging)
            logger?.error("PluginStore: import of \(source.path) failed: \(error)")
            throw PluginStoreError.ioFailure("\(error)")
        }
        logger?.info("PluginStore: imported \(component.manufacturerName): \(component.name) as \(id)")
        return ImportedPlugin(id: id, bundleURL: directory.appendingPathComponent(id).appendingPathComponent(name),
                              component: component)
    }

    public func delete(id: String) throws {
        guard let folder = folder(for: id) else { throw PluginStoreError.notFound }
        do {
            try fm.removeItem(at: folder)
        } catch {
            throw PluginStoreError.ioFailure("\(error)")
        }
    }

    public func loadState(id: String) -> Data? {
        guard let folder = folder(for: id) else { return nil }
        return try? Data(contentsOf: folder.appendingPathComponent("state.plist"))
    }

    public func saveState(id: String, _ data: Data) throws {
        guard let folder = folder(for: id) else { throw PluginStoreError.notFound }
        do {
            try data.write(to: folder.appendingPathComponent("state.plist"), options: .atomic)
        } catch {
            throw PluginStoreError.ioFailure("\(error)")
        }
    }

    // Ids come from config; only UUID-named folders that exist are reachable, so "../x" can't escape the directory.
    private func folder(for id: String) -> URL? {
        guard UUID(uuidString: id) != nil else { return nil }
        let url = directory.appendingPathComponent(id, isDirectory: true)
        return fm.fileExists(atPath: url.path) ? url : nil
    }

    private static func infoPlist(of bundle: URL) -> [String: Any] {
        guard let data = try? Data(contentsOf: bundle.appendingPathComponent("Contents/Info.plist")),
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else {
            return [:]
        }
        return plist
    }
}

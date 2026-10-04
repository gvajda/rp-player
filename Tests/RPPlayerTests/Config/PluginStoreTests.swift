import XCTest
@testable import RPPlayer

final class PluginStoreTests: XCTestCase {
    private var root: URL!
    private var sources: URL!
    private var store: PluginStore!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("plugin-store-\(UUID().uuidString)")
        sources = root.appendingPathComponent("sources")
        try FileManager.default.createDirectory(at: sources, withIntermediateDirectories: true)
        store = PluginStore(directory: root.appendingPathComponent("Plugins"),
                            architectures: { _ in [PluginValidator.hostArchitecture] })
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    func testImportCopiesBundleAndListsIt() async throws {
        let source = try PluginFixtures.makeComponent(in: sources)
        let imported = try await store.importComponent(from: source)

        XCTAssertNotNil(UUID(uuidString: imported.id))
        XCTAssertEqual(imported.bundleURL.lastPathComponent, "Console7Channel.component")
        XCTAssertTrue(FileManager.default.fileExists(atPath: imported.bundleURL.appendingPathComponent("Contents/Info.plist").path))
        XCTAssertEqual(imported.component.name, "Console7Channel")
        let listed = await store.list()
        XCTAssertEqual(listed, [imported])
        let lookedUp = await store.plugin(id: imported.id)
        XCTAssertEqual(lookedUp, imported)
    }

    func testRejectedImportCopiesNothing() async throws {
        let notEffect = try PluginFixtures.makeComponent(in: sources, named: "Synth",
                                                         entries: [PluginFixtures.componentEntry(type: "aumu")])
        do {
            _ = try await store.importComponent(from: notEffect)
            XCTFail("expected notAnEffect")
        } catch let error as PluginStoreError {
            XCTAssertEqual(error, .notAnEffect)
        }
        let first = try await store.importComponent(from: try PluginFixtures.makeComponent(in: sources))
        let again = try PluginFixtures.makeComponent(in: sources.appendingPathComponent("v2"))
        do {
            _ = try await store.importComponent(from: again)
            XCTFail("expected duplicate")
        } catch let error as PluginStoreError {
            XCTAssertEqual(error, .duplicate(name: "Console7Channel"))
        }
        let listed = await store.list()
        XCTAssertEqual(listed, [first])
        let folders = try FileManager.default.contentsOfDirectory(atPath: root.appendingPathComponent("Plugins").path)
        XCTAssertEqual(folders, [first.id], "a rejected import left something behind")
    }

    func testDeleteRemovesFolderAndRejectsNonUuidIds() async throws {
        let imported = try await store.importComponent(from: try PluginFixtures.makeComponent(in: sources))
        try await store.delete(id: imported.id)
        let listed = await store.list()
        XCTAssertEqual(listed, [])
        XCTAssertFalse(FileManager.default.fileExists(atPath: imported.bundleURL.deletingLastPathComponent().path))
        do {
            try await store.delete(id: "../sources")
            XCTFail("expected notFound")
        } catch let error as PluginStoreError {
            XCTAssertEqual(error, .notFound)
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: sources.path))
    }

    func testStateRoundTrip() async throws {
        let imported = try await store.importComponent(from: try PluginFixtures.makeComponent(in: sources))
        let noState = await store.loadState(id: imported.id)
        XCTAssertNil(noState)
        let data = try PropertyListSerialization.data(fromPropertyList: ["gain": 3.5], format: .binary, options: 0)
        try await store.saveState(id: imported.id, data)
        let loaded = await store.loadState(id: imported.id)
        XCTAssertEqual(loaded, data)
    }
}

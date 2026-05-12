import XCTest
@testable import RPPlayer

final class EqPresetStoreTests: XCTestCase {
    private var tmpDir: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("EqPresetStoreTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tmpDir)
        try super.tearDownWithError()
    }

    private func makeStore() -> LiveEqPresetStore {
        LiveEqPresetStore(directory: tmpDir)
    }

    func testSaveAndList() async throws {
        let store = makeStore()
        try await store.save(name: "alpha", text: "Filter 1: ON PK Fc 100 Hz Gain 0 dB Q 1.0\n", overwrite: false)
        try await store.save(name: "Bravo", text: "x", overwrite: false)
        let list = await store.list()
        XCTAssertEqual(list, ["alpha", "Bravo"])
    }

    func testLoadTextReturnsVerbatim() async throws {
        let store = makeStore()
        let text = "Preamp: -1 dB\nFilter 1: ON PK Fc 1000 Hz Gain 2 dB Q 1.0\n"
        try await store.save(name: "n", text: text, overwrite: false)
        let loaded = try await store.loadText(name: "n")
        XCTAssertEqual(loaded, text)
    }

    func testSaveRefusesOverwriteWhenFlagFalse() async throws {
        let store = makeStore()
        try await store.save(name: "n", text: "v1", overwrite: false)
        do {
            try await store.save(name: "n", text: "v2", overwrite: false)
            XCTFail("expected error")
        } catch EqPresetStoreError.alreadyExists {
            // expected
        }
    }

    func testSaveAllowsOverwriteWhenFlagTrue() async throws {
        let store = makeStore()
        try await store.save(name: "n", text: "v1", overwrite: false)
        try await store.save(name: "n", text: "v2", overwrite: true)
        let loaded = try await store.loadText(name: "n")
        XCTAssertEqual(loaded, "v2")
    }

    func testDeleteRemovesFile() async throws {
        let store = makeStore()
        try await store.save(name: "n", text: "x", overwrite: false)
        try await store.delete(name: "n")
        let list = await store.list()
        XCTAssertEqual(list, [])
    }

    func testExistsReturnsTrueAfterSave() async throws {
        let store = makeStore()
        let existsBefore = await store.exists(name: "n")
        XCTAssertFalse(existsBefore)
        try await store.save(name: "n", text: "x", overwrite: false)
        let existsAfter = await store.exists(name: "n")
        XCTAssertTrue(existsAfter)
    }

    func testRejectsFilenameWithSlash() async throws {
        let store = makeStore()
        do {
            try await store.save(name: "bad/name", text: "x", overwrite: false)
            XCTFail("expected error")
        } catch EqPresetStoreError.invalidName {
            // expected
        }
    }

    func testRejectsEmptyFilename() async throws {
        let store = makeStore()
        do {
            try await store.save(name: "", text: "x", overwrite: false)
            XCTFail("expected error")
        } catch EqPresetStoreError.invalidName {
            // expected
        }
    }

    func testRejectsLeadingDot() async throws {
        let store = makeStore()
        do {
            try await store.save(name: ".secret", text: "x", overwrite: false)
            XCTFail("expected error")
        } catch EqPresetStoreError.invalidName {
            // expected
        }
    }
}

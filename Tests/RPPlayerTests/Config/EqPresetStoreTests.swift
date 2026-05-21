import XCTest
@testable import RPPlayer

private final class CapturingLogger: Logging, @unchecked Sendable {
    private let lock = NSLock()
    private var _lines: [String] = []
    var lines: [String] {
        lock.lock(); defer { lock.unlock() }
        return _lines
    }
    func debug(_ message: @autoclosure () -> String) { record("debug", message()) }
    func info(_ message: @autoclosure () -> String)  { record("info",  message()) }
    func warn(_ message: @autoclosure () -> String)  { record("warn",  message()) }
    func error(_ message: @autoclosure () -> String) { record("error", message()) }
    private func record(_ level: String, _ msg: String) {
        lock.lock(); defer { lock.unlock() }
        _lines.append("\(level): \(msg)")
    }
}

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

    func testLoggerCapturesSaveSuccess() async throws {
        let logger = CapturingLogger()
        let store = LiveEqPresetStore(directory: tmpDir, logger: logger)
        try await store.save(name: "n", text: "x", overwrite: false)
        XCTAssertTrue(logger.lines.contains { $0.contains("EqPresetStore.save") && $0.contains("name=n") })
        XCTAssertTrue(logger.lines.contains { $0.contains("wrote=") })
    }

    func testRenameMovesFile() async throws {
        let store = makeStore()
        try await store.save(name: "alpha", text: "v1", overwrite: false)
        try await store.rename(from: "alpha", to: "beta")
        let names = await store.list()
        XCTAssertEqual(names, ["beta"])
        let text = try await store.loadText(name: "beta")
        XCTAssertEqual(text, "v1")
    }

    func testRenameSameNameIsNoOp() async throws {
        let store = makeStore()
        try await store.save(name: "n", text: "v", overwrite: false)
        try await store.rename(from: "n", to: "n")
        let text = try await store.loadText(name: "n")
        XCTAssertEqual(text, "v")
    }

    func testRenameThrowsNotFound() async throws {
        let store = makeStore()
        do {
            try await store.rename(from: "missing", to: "anything")
            XCTFail("expected error")
        } catch EqPresetStoreError.notFound {
            // expected
        }
    }

    func testRenameThrowsAlreadyExists() async throws {
        let store = makeStore()
        try await store.save(name: "a", text: "1", overwrite: false)
        try await store.save(name: "b", text: "2", overwrite: false)
        do {
            try await store.rename(from: "a", to: "b")
            XCTFail("expected error")
        } catch EqPresetStoreError.alreadyExists {
            // expected
        }
        let a = try await store.loadText(name: "a")
        let b = try await store.loadText(name: "b")
        XCTAssertEqual(a, "1")
        XCTAssertEqual(b, "2")
    }

    func testRenameInvalidNameRejectedBothSides() async throws {
        let store = makeStore()
        try await store.save(name: "ok", text: "x", overwrite: false)
        do {
            try await store.rename(from: "ok", to: "bad/name")
            XCTFail("expected error")
        } catch EqPresetStoreError.invalidName {}
        do {
            try await store.rename(from: "bad/name", to: "ok2")
            XCTFail("expected error")
        } catch EqPresetStoreError.invalidName {}
    }

    func testSaveRejectsNameOverThirtyChars() async throws {
        let store = makeStore()
        let n31 = String(repeating: "a", count: 31)
        do {
            try await store.save(name: n31, text: "x", overwrite: false)
            XCTFail("expected error")
        } catch EqPresetStoreError.invalidName {}
    }

    func testSaveAllowsExactlyThirtyChars() async throws {
        let store = makeStore()
        let n30 = String(repeating: "a", count: 30)
        try await store.save(name: n30, text: "x", overwrite: false)
        let exists = await store.exists(name: n30)
        XCTAssertTrue(exists)
    }
}

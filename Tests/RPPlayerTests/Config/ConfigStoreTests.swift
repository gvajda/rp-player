import XCTest
@testable import RPPlayer

final class ConfigStoreTests: XCTestCase {
    private func makeTempURL() -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("RPPlayerTests-\(UUID().uuidString)", isDirectory: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        return dir.appendingPathComponent("config.json")
    }

    func testLoadsDefaultsWhenFileMissing() async throws {
        let url = makeTempURL()
        let store = try JSONConfigStore(url: url)
        let s = await store.settings
        XCTAssertEqual(s, .default)
    }

    func testRoundTripAcrossInstances() async throws {
        let url = makeTempURL()
        let store1 = try JSONConfigStore(url: url)
        try await store1.update {
            $0.selectedChannelId = 5
            $0.hogModeEnabled = false
        }

        let store2 = try JSONConfigStore(url: url)
        let s = await store2.settings
        XCTAssertEqual(s.selectedChannelId, 5)
        XCTAssertFalse(s.hogModeEnabled)
    }

    func testUpdateEmitsChange() async throws {
        let url = makeTempURL()
        let store = try JSONConfigStore(url: url)
        let stream = await store.changes
        let received = Task { () -> AppSettings? in
            for await s in stream {
                if s.selectedChannelId == 7 { return s }
            }
            return nil
        }
        try await store.update { $0.selectedChannelId = 7 }
        let result = await received.value
        XCTAssertEqual(result?.selectedChannelId, 7)
    }

    func testNoOpUpdateDoesNotEmit() async throws {
        let url = makeTempURL()
        let store = try JSONConfigStore(url: url)
        try await store.update { $0.selectedChannelId = 5 }

        let stream = await store.changes
        let collector = Task { () -> [Int] in
            var ids: [Int] = []
            for await s in stream {
                ids.append(s.selectedChannelId)
                if ids.count == 2 { return ids }
            }
            return ids
        }
        try await store.update { $0.selectedChannelId = 5 } // no-op
        try await store.update { $0.selectedChannelId = 6 } // change
        let ids = await collector.value
        // First emission is the current snapshot (5); second is the real change (6).
        XCTAssertEqual(ids, [5, 6])
    }
}

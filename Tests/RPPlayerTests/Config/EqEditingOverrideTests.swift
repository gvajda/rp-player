import XCTest
@testable import RPPlayer

final class EqEditingOverrideTests: XCTestCase {
    func testInitialSnapshotIsNil() async {
        let holder = EqEditingOverride()
        let snap = await holder.snapshot()
        XCTAssertNil(snap)
    }

    func testSetThenSnapshotReturnsValue() async {
        let holder = EqEditingOverride()
        let preset = EqPreset(name: nil, preampDb: -2, bands: [
            EqBand(enabled: true, type: .peak, fcHz: 1000, gainDb: 3, q: 1)
        ])
        await holder.set(preset)
        let snap = await holder.snapshot()
        XCTAssertEqual(snap, preset)
    }

    func testChangesStreamYieldsUpdates() async throws {
        let holder = EqEditingOverride()
        let stream = await holder.changes
        let collector = Task<[EqPreset?], Never> {
            var collected: [EqPreset?] = []
            for await value in stream {
                collected.append(value)
                if collected.count == 3 { break }
            }
            return collected
        }
        try await Task.sleep(nanoseconds: 20_000_000)
        let p1 = EqPreset(name: nil, preampDb: 0, bands: [])
        let p2 = EqPreset(name: nil, preampDb: -1, bands: [])
        await holder.set(p1)
        await holder.set(p2)
        await holder.set(nil)
        let out = await collector.value
        XCTAssertEqual(out, [p1, p2, nil])
    }

    func testMultipleSubscribersAllReceiveValues() async throws {
        let holder = EqEditingOverride()
        let s1 = await holder.changes
        let s2 = await holder.changes
        async let c1: EqPreset? = {
            for await v in s1 { return v }
            return nil
        }()
        async let c2: EqPreset? = {
            for await v in s2 { return v }
            return nil
        }()
        try await Task.sleep(nanoseconds: 20_000_000)
        let p = EqPreset(name: nil, preampDb: 1, bands: [])
        await holder.set(p)
        let (r1, r2) = await (c1, c2)
        XCTAssertEqual(r1, p)
        XCTAssertEqual(r2, p)
    }
}

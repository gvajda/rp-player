import XCTest
@testable import RPPlayer

final class LibmpvPlayerEngineTests: XCTestCase {
    func testInitAndShutdownDoesNotCrash() async throws {
        let engine = try LibmpvPlayerEngine()
        await engine.shutdown()
    }

    func testShutdownIsIdempotent() async throws {
        let engine = try LibmpvPlayerEngine()
        await engine.shutdown()
        await engine.shutdown()
    }

    func testCommandsAfterShutdownThrowAlreadyShutdown() async throws {
        let engine = try LibmpvPlayerEngine()
        await engine.shutdown()
        do {
            try await engine.pause()
            XCTFail("expected alreadyShutdown")
        } catch let error as PlayerEngineError {
            XCTAssertEqual(error, .alreadyShutdown)
        }
    }
}

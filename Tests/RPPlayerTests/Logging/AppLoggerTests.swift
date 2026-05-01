import XCTest
@testable import RPPlayer

final class AppLoggerTests: XCTestCase {
    private func makeTempDir() -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("RPPlayerTests-\(UUID().uuidString)", isDirectory: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    func testFileBackedFactoryCreatesDirectoryAndWritesEmittedLines() throws {
        let dir = makeTempDir()
        XCTAssertFalse(FileManager.default.fileExists(atPath: dir.path))

        let logger = AppLogger.fileBacked(category: "shell", directory: dir)
        logger.error("hello world")

        let logFile = dir.appendingPathComponent("RPPlayer.log")
        let contents = try String(contentsOf: logFile, encoding: .utf8)
        XCTAssertTrue(contents.contains("hello world"))
        XCTAssertTrue(contents.contains("[ERROR]"))
        XCTAssertTrue(contents.contains("[shell]"))
    }

    func testFileBackedFactoryFallsBackWhenSinkConstructionFails() {
        let badDir = URL(fileURLWithPath: "/dev/null/cannot-create-here")
        let logger = AppLogger.fileBacked(category: "shell", directory: badDir)
        logger.error("must not crash")
    }

    func testSetMinimumLevelChangesEmissionThreshold() throws {
        let dir = makeTempDir()
        let logger = AppLogger.fileBacked(category: "shell", directory: dir, minimumLevel: .info)
        logger.debug("before-flip")
        logger.setMinimumLevel(.debug)
        logger.debug("after-flip")

        let logFile = dir.appendingPathComponent("RPPlayer.log")
        let contents = try String(contentsOf: logFile, encoding: .utf8)
        XCTAssertFalse(contents.contains("before-flip"))
        XCTAssertTrue(contents.contains("after-flip"))
    }

    func testSetVerboseFlipsThresholdToDebugAndBack() throws {
        let dir = makeTempDir()
        let logger = AppLogger.fileBacked(category: "shell", directory: dir, minimumLevel: .info)
        logger.debug("hidden")
        logger.setVerbose(true)
        logger.debug("visible-on")
        logger.setVerbose(false)
        logger.debug("hidden-again")

        let logFile = dir.appendingPathComponent("RPPlayer.log")
        let contents = try String(contentsOf: logFile, encoding: .utf8)
        XCTAssertFalse(contents.contains("hidden"))
        XCTAssertTrue(contents.contains("visible-on"))
        XCTAssertFalse(contents.contains("hidden-again"))
    }
}

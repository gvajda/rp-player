import XCTest
@testable import RPPlayer

final class RotatingFileSinkTests: XCTestCase {
    private func makeTempDir() -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("RPPlayerTests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    func testWritesToCurrentLog() throws {
        let dir = makeTempDir()
        let sink = try RotatingFileSink(
            directory: dir, baseName: "Test", fileExtension: "log",
            maxFileBytes: 1024, maxFiles: 3
        )
        sink.writeLine("hello")
        let url = dir.appendingPathComponent("Test.log")
        let contents = try String(contentsOf: url, encoding: .utf8)
        XCTAssertTrue(contents.contains("hello"))
    }

    func testRotatesWhenSizeExceeded() throws {
        let dir = makeTempDir()
        let sink = try RotatingFileSink(
            directory: dir, baseName: "Test", fileExtension: "log",
            maxFileBytes: 100, maxFiles: 3
        )
        let line = String(repeating: "x", count: 90)
        sink.writeLine(line)
        sink.writeLine(line)
        sink.writeLine(line)

        let fm = FileManager.default
        XCTAssertTrue(fm.fileExists(atPath: dir.appendingPathComponent("Test.log").path))
        XCTAssertTrue(fm.fileExists(atPath: dir.appendingPathComponent("Test.1.log").path))
    }

    func testDropsOldestBeyondMaxFiles() throws {
        let dir = makeTempDir()
        let sink = try RotatingFileSink(
            directory: dir, baseName: "Test", fileExtension: "log",
            maxFileBytes: 100, maxFiles: 2
        )
        let line = String(repeating: "x", count: 90)
        for _ in 0..<6 { sink.writeLine(line) }

        let fm = FileManager.default
        XCTAssertTrue(fm.fileExists(atPath: dir.appendingPathComponent("Test.log").path))
        XCTAssertTrue(fm.fileExists(atPath: dir.appendingPathComponent("Test.1.log").path))
        XCTAssertTrue(fm.fileExists(atPath: dir.appendingPathComponent("Test.2.log").path))
        XCTAssertFalse(fm.fileExists(atPath: dir.appendingPathComponent("Test.3.log").path))
    }
}

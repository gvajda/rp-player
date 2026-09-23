import XCTest
@testable import RPPlayer

final class PluginBridgeTests: XCTestCase {
    func testFilterPartLeavesSpacesAlone() {
        XCTAssertEqual(
            PluginBridge.filterPart(path: "/Applications/RP Player.app/Contents/Frameworks/libRPBridge.dylib"),
            "ladspa=file=/Applications/RP Player.app/Contents/Frameworks/libRPBridge.dylib:p=rpbridge")
    }

    func testFilterPartEscapesForBothLavfiParsingLevels() {
        XCTAssertEqual(
            PluginBridge.filterPart(path: #"/tmp/a b/it's: x, y; z\w/libRPBridge.dylib"#),
            #"ladspa=file=/tmp/a b/it\\\'s\\: x\, y\; z\\\\w/libRPBridge.dylib:p=rpbridge"#)
    }

    func testFilterPartRejectsBrackets() {
        XCTAssertNil(PluginBridge.filterPart(path: "/tmp/[x]/libRPBridge.dylib"))
        XCTAssertNil(PluginBridge.filterPart(path: "/tmp/x]/libRPBridge.dylib"))
    }

    func testDefaultPathPrefersBundleFrameworks() throws {
        let app = try makeFakeApp(dylibIn: "Frameworks")
        defer { try? FileManager.default.removeItem(at: app.deletingLastPathComponent()) }
        let expected = app.appendingPathComponent("Contents/Frameworks/libRPBridge.dylib").resolvingSymlinksInPath().path
        XCTAssertEqual(PluginBridge.defaultPath(bundle: try XCTUnwrap(Bundle(url: app))), expected)
    }

    func testDefaultPathFallsBackToExecutableDirectory() throws {
        let app = try makeFakeApp(dylibIn: "MacOS")
        defer { try? FileManager.default.removeItem(at: app.deletingLastPathComponent()) }
        let expected = app.appendingPathComponent("Contents/MacOS/libRPBridge.dylib").resolvingSymlinksInPath().path
        XCTAssertEqual(PluginBridge.defaultPath(bundle: try XCTUnwrap(Bundle(url: app))), expected)
    }

    func testLoadSucceedsOnBuiltDylibAndFailsOnMissingFile() {
        let bridge = PluginBridge.load(path: RPBridgeTestSupport.dylibPath, logger: nil)
        XCTAssertNotNil(bridge)
        XCTAssertEqual(bridge?.path, URL(fileURLWithPath: RPBridgeTestSupport.dylibPath).resolvingSymlinksInPath().path)
        XCTAssertNil(PluginBridge.load(path: "/nonexistent/libRPBridge.dylib", logger: nil))
    }

    private func makeFakeApp(dylibIn folder: String) throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let app = root.appendingPathComponent("Fake.app")
        let contents = app.appendingPathComponent("Contents")
        for dir in ["MacOS", "Frameworks"] {
            try FileManager.default.createDirectory(at: contents.appendingPathComponent(dir), withIntermediateDirectories: true)
        }
        let plist: [String: Any] = [
            "CFBundleIdentifier": "com.example.fake", "CFBundleExecutable": "Fake", "CFBundlePackageType": "APPL",
        ]
        try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
            .write(to: contents.appendingPathComponent("Info.plist"))
        FileManager.default.createFile(atPath: contents.appendingPathComponent("MacOS/Fake").path, contents: Data())
        FileManager.default.createFile(atPath: contents.appendingPathComponent("\(folder)/libRPBridge.dylib").path, contents: Data())
        return app
    }
}

import AppKit
import XCTest
@testable import RPPlayer

@MainActor
final class MainMenuBuilderTests: XCTestCase {
    func testReturnedMenuHasAppAndEditSubmenus() {
        let menu = MainMenuBuilder.build(appName: "RP Player")
        XCTAssertEqual(menu.items.count, 2)
        let titles = menu.items.compactMap { $0.submenu?.title }
        XCTAssertEqual(titles, ["RP Player", "Edit"])
    }

    func testAppMenuContainsQuitWithTerminateSelector() throws {
        let menu = MainMenuBuilder.build(appName: "RP Player")
        let appMenu = try XCTUnwrap(menu.items.first?.submenu)
        let quit = try XCTUnwrap(appMenu.items.first(where: { $0.title == "Quit RP Player" }))
        XCTAssertEqual(quit.action, Selector(("terminate:")))
        XCTAssertEqual(quit.keyEquivalent, "q")
        XCTAssertTrue(quit.keyEquivalentModifierMask.contains(.command))
    }

    func testAppMenuContainsAboutHideShowAll() throws {
        let menu = MainMenuBuilder.build(appName: "RP Player")
        let appMenu = try XCTUnwrap(menu.items.first?.submenu)
        let titles = appMenu.items.map { $0.title }
        XCTAssertTrue(titles.contains("About RP Player"))
        XCTAssertTrue(titles.contains("Hide RP Player"))
        XCTAssertTrue(titles.contains("Hide Others"))
        XCTAssertTrue(titles.contains("Show All"))
    }

    func testEditMenuContainsStandardEditSelectors() throws {
        let menu = MainMenuBuilder.build(appName: "RP Player")
        let editMenu = try XCTUnwrap(menu.items.last?.submenu)
        func find(_ title: String) -> NSMenuItem? {
            editMenu.items.first(where: { $0.title == title })
        }
        XCTAssertEqual(find("Cut")?.action, Selector(("cut:")))
        XCTAssertEqual(find("Copy")?.action, Selector(("copy:")))
        XCTAssertEqual(find("Paste")?.action, Selector(("paste:")))
        XCTAssertEqual(find("Select All")?.action, Selector(("selectAll:")))

        XCTAssertEqual(find("Cut")?.keyEquivalent, "x")
        XCTAssertEqual(find("Copy")?.keyEquivalent, "c")
        XCTAssertEqual(find("Paste")?.keyEquivalent, "v")
        XCTAssertEqual(find("Select All")?.keyEquivalent, "a")
    }

    func testEditMenuContainsUndoRedoBlock() throws {
        let menu = MainMenuBuilder.build(appName: "RP Player")
        let editMenu = try XCTUnwrap(menu.items.last?.submenu)
        let undo = try XCTUnwrap(editMenu.items.first(where: { $0.title == "Undo" }))
        let redo = try XCTUnwrap(editMenu.items.first(where: { $0.title == "Redo" }))
        XCTAssertEqual(undo.action, Selector(("undo:")))
        XCTAssertEqual(undo.keyEquivalent, "z")
        XCTAssertTrue(undo.keyEquivalentModifierMask.contains(.command))

        XCTAssertEqual(redo.action, Selector(("redo:")))
        XCTAssertEqual(redo.keyEquivalent, "z")
        XCTAssertTrue(redo.keyEquivalentModifierMask.contains([.command, .shift]))
    }

    func testAllItemTargetsAreNilForResponderChainRouting() {
        let menu = MainMenuBuilder.build(appName: "RP Player")
        for top in menu.items {
            for item in top.submenu?.items ?? [] {
                if item.isSeparatorItem { continue }
                XCTAssertNil(item.target, "\(item.title) should have nil target so AppKit routes via responder chain")
            }
        }
    }
}

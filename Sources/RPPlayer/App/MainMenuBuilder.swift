import AppKit

enum MainMenuBuilder {
    @MainActor
    static func build(appName: String = ProcessInfo.processInfo.processName) -> NSMenu {
        let menubar = NSMenu(title: "MainMenu")
        menubar.addItem(buildAppMenuItem(appName: appName))
        menubar.addItem(buildEditMenuItem())
        return menubar
    }

    @MainActor
    private static func buildAppMenuItem(appName: String) -> NSMenuItem {
        let item = NSMenuItem()
        let submenu = NSMenu(title: appName)

        submenu.addItem(plain(
            title: "About \(appName)",
            action: Selector(("orderFrontStandardAboutPanel:"))
        ))
        submenu.addItem(.separator())

        submenu.addItem(plain(
            title: "Hide \(appName)",
            action: Selector(("hide:")),
            keyEquivalent: "h"
        ))
        let hideOthers = plain(
            title: "Hide Others",
            action: Selector(("hideOtherApplications:")),
            keyEquivalent: "h"
        )
        hideOthers.keyEquivalentModifierMask = [.command, .option]
        submenu.addItem(hideOthers)
        submenu.addItem(plain(
            title: "Show All",
            action: Selector(("unhideAllApplications:"))
        ))
        submenu.addItem(.separator())

        submenu.addItem(plain(
            title: "Quit \(appName)",
            action: Selector(("terminate:")),
            keyEquivalent: "q"
        ))

        item.submenu = submenu
        return item
    }

    @MainActor
    private static func buildEditMenuItem() -> NSMenuItem {
        let item = NSMenuItem()
        let submenu = NSMenu(title: "Edit")

        submenu.addItem(plain(
            title: "Undo",
            action: Selector(("undo:")),
            keyEquivalent: "z"
        ))
        let redo = plain(
            title: "Redo",
            action: Selector(("redo:")),
            keyEquivalent: "z"
        )
        redo.keyEquivalentModifierMask = [.command, .shift]
        submenu.addItem(redo)
        submenu.addItem(.separator())

        submenu.addItem(plain(title: "Cut",   action: Selector(("cut:")),   keyEquivalent: "x"))
        submenu.addItem(plain(title: "Copy",  action: Selector(("copy:")),  keyEquivalent: "c"))
        submenu.addItem(plain(title: "Paste", action: Selector(("paste:")), keyEquivalent: "v"))
        submenu.addItem(plain(
            title: "Select All",
            action: Selector(("selectAll:")),
            keyEquivalent: "a"
        ))

        item.submenu = submenu
        return item
    }

    @MainActor
    private static func plain(
        title: String,
        action: Selector,
        keyEquivalent: String = ""
    ) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: keyEquivalent)
        item.target = nil
        return item
    }
}

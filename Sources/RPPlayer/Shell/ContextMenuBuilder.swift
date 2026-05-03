import AppKit

@MainActor
enum ContextMenuBuilder {
    static func build(viewModel: MiniPlayerViewModel?) -> NSMenu {
        let menu = NSMenu()
        // Without this, AppKit auto-validates each item via target-action and
        // overrides our explicit isEnabled = false on "Open Song in Browser".
        menu.autoenablesItems = false

        menu.addItem(item("Settings…") { viewModel?.openSettings() })
        let openSong = item("Open Song in Browser") { viewModel?.openCurrentSongInBrowser() }
        openSong.isEnabled = viewModel?.nowPlaying != nil
        menu.addItem(openSong)

        menu.addItem(item("Upcoming Program…") { viewModel?.openUpcoming() })

        let floatItem = item("Floating Window") { viewModel?.togglePopoverFloating() }
        floatItem.state = (viewModel?.popoverFloatingEnabled == true) ? .on : .off
        menu.addItem(floatItem)

        menu.addItem(.separator())
        menu.addItem(item("About RP Player") { viewModel?.openAbout() })
        menu.addItem(.separator())
        menu.addItem(item("Quit RP Player") { NSApp.terminate(nil) })

        return menu
    }

    private static func item(_ title: String, handler: @escaping @MainActor () -> Void) -> NSMenuItem {
        let h = MenuItemHandler(handler)
        let menuItem = NSMenuItem(title: title, action: #selector(MenuItemHandler.invoke), keyEquivalent: "")
        menuItem.target = h
        menuItem.representedObject = h  // NSMenuItem.target is weak; retain via representedObject
        return menuItem
    }
}

@MainActor
private final class MenuItemHandler: NSObject {
    private let handler: @MainActor () -> Void
    init(_ handler: @escaping @MainActor () -> Void) { self.handler = handler }
    @objc func invoke() { handler() }
}

import AppKit

@MainActor
final class StatusItemController {
    let statusItem: NSStatusItem
    private let popover: PopoverController
    private let showHandler: (NSView) -> Void
    private let closeHandler: () -> Void
    private let menuProvider: (() -> NSMenu)?

    init(
        statusBar: NSStatusBar = .system,
        popover: PopoverController,
        menuProvider: (() -> NSMenu)? = nil,
        show: ((NSView) -> Void)? = nil,
        close: (() -> Void)? = nil
    ) {
        let item = statusBar.statusItem(withLength: NSStatusItem.variableLength)
        if let url = Bundle.module.url(forResource: "rp", withExtension: "ico"),
           let image = NSImage(contentsOf: url) {
            image.size = NSSize(width: 18, height: 18)
            item.button?.image = image
        } else {
            let fallback = NSImage(systemSymbolName: "music.note", accessibilityDescription: "RP Player")
            fallback?.isTemplate = true
            item.button?.image = fallback
        }
        item.button?.toolTip = "RP Player"

        self.statusItem = item
        self.popover = popover
        self.menuProvider = menuProvider
        self.showHandler = show ?? { anchor in popover.show(relativeTo: anchor) }
        self.closeHandler = close ?? { popover.close() }

        item.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])
        item.button?.target = self
        item.button?.action = #selector(buttonClicked(_:))
    }

    func toggle() {
        if popover.isShown {
            closeHandler()
        } else if let button = statusItem.button {
            showHandler(button)
        }
    }

    func closeIfShown() {
        if popover.isShown {
            closeHandler()
        }
    }

    func showPopoverIfNeeded() {
        guard !popover.isShown, let button = statusItem.button else { return }
        showHandler(button)
    }

    @objc private func buttonClicked(_ sender: NSStatusBarButton) {
        if NSApp.currentEvent?.type == .rightMouseUp {
            showContextMenu(from: sender)
        } else {
            toggle()
        }
    }

    private func showContextMenu(from button: NSStatusBarButton) {
        guard let menu = menuProvider?() else { return }
        statusItem.menu = menu
        button.performClick(nil)
        statusItem.menu = nil
    }
}

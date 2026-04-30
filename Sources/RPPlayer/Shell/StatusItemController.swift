import AppKit

@MainActor
final class StatusItemController {
    let statusItem: NSStatusItem
    private let popover: PopoverController
    private let showHandler: (NSView) -> Void
    private let closeHandler: () -> Void

    init(
        statusBar: NSStatusBar = .system,
        popover: PopoverController,
        show: ((NSView) -> Void)? = nil,
        close: (() -> Void)? = nil
    ) {
        let item = statusBar.statusItem(withLength: NSStatusItem.variableLength)
        let image = NSImage(systemSymbolName: "music.note", accessibilityDescription: "RP Player")
        image?.isTemplate = true
        item.button?.image = image
        item.button?.toolTip = "RP Player"

        self.statusItem = item
        self.popover = popover
        // .accessory apps need an explicit activate so the popover gets key focus —
        // without it, .transient won't dismiss on outside click and layout can place
        // the popover on top of the status item.
        self.showHandler = show ?? { anchor in
            NSApp.activate(ignoringOtherApps: true)
            popover.show(relativeTo: anchor)
        }
        self.closeHandler = close ?? { popover.close() }

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

    @objc private func buttonClicked(_ sender: NSStatusBarButton) {
        toggle()
    }
}

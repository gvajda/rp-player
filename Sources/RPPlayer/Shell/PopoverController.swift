import AppKit
import SwiftUI

@MainActor
final class PopoverController {
    let popover: NSPopover

    init() {
        let popover = NSPopover()
        popover.contentSize = NSSize(width: 320, height: 420)
        popover.behavior = .transient
        popover.contentViewController = NSHostingController(rootView: AppShellPlaceholderView())
        self.popover = popover
    }

    var isShown: Bool { popover.isShown }

    func show(relativeTo anchor: NSView) {
        popover.show(relativeTo: anchor.bounds, of: anchor, preferredEdge: .minY)
    }

    func close() {
        popover.performClose(nil)
    }
}

import AppKit
import SwiftUI

@MainActor
class PopoverController {
    static let contentSize = NSSize(width: 320, height: 420)

    let panel: NSPanel
    private var clickMonitor: Any?

    init() {
        let hostingView = NSHostingView(rootView: AppShellPlaceholderView())
        hostingView.frame = NSRect(origin: .zero, size: Self.contentSize)

        let panel = NSPanel(
            contentRect: NSRect(origin: .zero, size: Self.contentSize),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isFloatingPanel = true
        panel.level = .statusBar
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.isReleasedWhenClosed = false
        panel.contentView = hostingView
        panel.contentView?.wantsLayer = true
        panel.contentView?.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
        panel.contentView?.layer?.cornerRadius = 10
        panel.contentView?.layer?.masksToBounds = true

        self.panel = panel
    }

    var isShown: Bool { panel.isVisible }

    func show(relativeTo anchor: NSView) {
        guard let buttonWindow = anchor.window else { return }
        let buttonRectInScreen = buttonWindow.convertToScreen(
            anchor.convert(anchor.bounds, to: nil)
        )
        // Panel top should sit flush with the bottom of the menu bar (= the
        // status item window's minY), not the button frame's minY — the button
        // is a few px shorter than its window and leaves a visible gap.
        let panelSize = panel.frame.size
        let origin = NSPoint(
            x: buttonRectInScreen.midX - panelSize.width / 2,
            y: buttonWindow.frame.minY - panelSize.height
        )
        panel.setFrameOrigin(origin)
        panel.orderFrontRegardless()
        installClickMonitor()
    }

    func close() {
        removeClickMonitor()
        panel.orderOut(nil)
    }

    private func installClickMonitor() {
        guard clickMonitor == nil else { return }
        clickMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown]
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.close()
            }
        }
    }

    private func removeClickMonitor() {
        if let monitor = clickMonitor {
            NSEvent.removeMonitor(monitor)
            clickMonitor = nil
        }
    }
}

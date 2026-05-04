import AppKit
import SwiftUI

@MainActor
class PopoverController {
    static let contentSize = NSSize(width: 342, height: 540)
    private static let escapeKeyCode: UInt16 = 53

    let panel: NSPanel
    private var globalClickMonitor: Any?
    private var localKeyMonitor: Any?
    private var floatingMode: Bool = false

    init(rootView: AnyView) {
        let wrapped = AnyView(
            rootView
                .background(Color(nsColor: .windowBackgroundColor))
        )
        let hostingView = NSHostingView(rootView: wrapped)
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
        panel.contentView?.layer?.cornerRadius = 10
        panel.contentView?.layer?.masksToBounds = true

        self.panel = panel
    }

    var isShown: Bool { panel.isVisible }
    var isFloating: Bool { floatingMode }

    func show(relativeTo anchor: NSView) {
        if floatingMode {
            // First show in floating mode anchors to the icon for visual
            // continuity; subsequent shows reuse whatever position the user
            // dragged the panel to.
            if !panel.isVisible {
                positionAnchored(to: anchor)
            }
            panel.orderFrontRegardless()
            return
        }
        positionAnchored(to: anchor)
        // Activate so the panel comes to the foreground; otherwise the global
        // monitor never sees the user's outside clicks until they activate the app.
        NSApp.activate(ignoringOtherApps: true)
        panel.orderFrontRegardless()
        installMonitors()
    }

    func close() {
        removeMonitors()
        panel.orderOut(nil)
    }

    func setFloatingMode(_ enabled: Bool) {
        guard enabled != floatingMode else { return }
        floatingMode = enabled
        if enabled {
            removeMonitors()
            panel.level = .floating
            panel.isMovableByWindowBackground = true
            panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        } else {
            panel.level = .statusBar
            panel.isMovableByWindowBackground = false
            panel.collectionBehavior = []
            // Per spec: toggling off closes the panel; next status-icon click
            // re-shows it anchored as normal.
            if panel.isVisible {
                close()
            }
        }
    }

    private func positionAnchored(to anchor: NSView) {
        guard let buttonWindow = anchor.window else { return }
        let buttonRectInScreen = buttonWindow.convertToScreen(
            anchor.convert(anchor.bounds, to: nil)
        )
        // Panel top sits flush with the menu-bar bottom (= the status item
        // window's minY); using the button's bounds.minY would leave a 2-3 px
        // gap because the button is shorter than its window.
        let panelSize = panel.frame.size
        let origin = NSPoint(
            x: buttonRectInScreen.midX - panelSize.width / 2,
            y: buttonWindow.frame.minY - panelSize.height
        )
        panel.setFrameOrigin(origin)
    }

    private func installMonitors() {
        if globalClickMonitor == nil {
            globalClickMonitor = NSEvent.addGlobalMonitorForEvents(
                matching: [.leftMouseDown, .rightMouseDown]
            ) { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.close()
                }
            }
        }
        if localKeyMonitor == nil {
            localKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                guard let self, event.window === self.panel else { return event }
                if event.keyCode == Self.escapeKeyCode {
                    Task { @MainActor [weak self] in
                        self?.close()
                    }
                    return nil
                }
                return event
            }
        }
    }

    private func removeMonitors() {
        if let monitor = globalClickMonitor {
            NSEvent.removeMonitor(monitor)
            globalClickMonitor = nil
        }
        if let monitor = localKeyMonitor {
            NSEvent.removeMonitor(monitor)
            localKeyMonitor = nil
        }
    }
}

import AppKit
import SwiftUI

@MainActor
final class PastSongPopoverController {
    private static let contentSize = NSSize(width: 342, height: 540)
    private static let escapeKeyCode: UInt16 = 53

    private let panel: NSPanel
    private var hostingView: NSHostingView<AnyView>?
    private var globalClickMonitor: Any?
    private var localKeyMonitor: Any?

    init() {
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
        self.panel = panel
    }

    var isShown: Bool { panel.isVisible }

    func present(viewModel: PastSongViewModel, relativeTo anchor: NSView) {
        let root = AnyView(
            PastSongView(viewModel: viewModel)
                .background(Color(nsColor: .windowBackgroundColor))
        )
        let host = NSHostingView(rootView: root)
        host.frame = NSRect(origin: .zero, size: Self.contentSize)
        panel.contentView = host
        panel.contentView?.wantsLayer = true
        panel.contentView?.layer?.cornerRadius = 10
        panel.contentView?.layer?.masksToBounds = true
        hostingView = host

        guard let buttonWindow = anchor.window else { return }
        let buttonRectInScreen = buttonWindow.convertToScreen(
            anchor.convert(anchor.bounds, to: nil)
        )
        NSApp.activate(ignoringOtherApps: true)
        let panelSize = panel.frame.size
        let origin = NSPoint(
            x: buttonRectInScreen.midX - panelSize.width / 2,
            y: buttonWindow.frame.minY - panelSize.height
        )
        panel.setFrameOrigin(origin)
        panel.orderFrontRegardless()
        installMonitors()
    }

    func close() {
        removeMonitors()
        panel.orderOut(nil)
        hostingView = nil
        panel.contentView = nil
    }

    private func installMonitors() {
        if globalClickMonitor == nil {
            globalClickMonitor = NSEvent.addGlobalMonitorForEvents(
                matching: [.leftMouseDown, .rightMouseDown]
            ) { [weak self] _ in
                Task { @MainActor [weak self] in self?.close() }
            }
        }
        if localKeyMonitor == nil {
            localKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                guard let self, event.window === self.panel else { return event }
                if event.keyCode == Self.escapeKeyCode {
                    Task { @MainActor [weak self] in self?.close() }
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

import AppKit
import SwiftUI

@MainActor
final class SettingsWindowController: NSWindowController {
    static let contentSize = NSSize(width: 480, height: 560)
    static let contentMinSize = NSSize(width: 480, height: 400)
    static let contentMaxSize = NSSize(width: 480, height: 2000)

    init(viewModel: SettingsViewModel) {
        let hosting = NSHostingController(rootView: SettingsView(viewModel: viewModel))
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: Self.contentSize),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "RP Player Settings"
        window.contentViewController = hosting
        window.setContentSize(Self.contentSize)
        window.contentMinSize = Self.contentMinSize
        window.contentMaxSize = Self.contentMaxSize
        window.center()
        window.isReleasedWhenClosed = false
        window.initialFirstResponder = nil
        super.init(window: window)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("use init(viewModel:)") }

    var isVisible: Bool { window?.isVisible ?? false }

    func show() {
        window?.makeKeyAndOrderFront(nil)
        window?.makeFirstResponder(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func hide() {
        window?.orderOut(nil)
    }
}

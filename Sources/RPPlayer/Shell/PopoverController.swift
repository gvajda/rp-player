import AppKit
import SwiftUI

@MainActor
class PopoverController {
    static let contentSize = NSSize(width: 342, height: 540)
    private static let escapeKeyCode: UInt16 = 53

    let panel: NSPanel
    private let configStore: any ConfigStore
    private let container: NSView
    private let frostedView: NSVisualEffectView
    private let hostingView: NSHostingView<AnyView>
    private var globalClickMonitor: Any?
    private var localKeyMonitor: Any?
    private var floatingMode: Bool = false
    private var settingsTask: Task<Void, Never>?

    init(rootView: AnyView, configStore: any ConfigStore) {
        self.configStore = configStore

        let container = NSView(frame: NSRect(origin: .zero, size: Self.contentSize))
        container.wantsLayer = true
        container.layer?.cornerRadius = 10
        container.layer?.masksToBounds = true

        let frostedView = NSVisualEffectView()
        frostedView.material = .hudWindow
        frostedView.blendingMode = .behindWindow
        frostedView.state = .active
        frostedView.translatesAutoresizingMaskIntoConstraints = false
        frostedView.isHidden = true
        container.addSubview(frostedView)
        NSLayoutConstraint.activate([
            frostedView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            frostedView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            frostedView.topAnchor.constraint(equalTo: container.topAnchor),
            frostedView.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])

        let hostingView = NSHostingView(rootView: rootView)
        hostingView.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(hostingView)
        NSLayoutConstraint.activate([
            hostingView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            hostingView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            hostingView.topAnchor.constraint(equalTo: container.topAnchor),
            hostingView.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])

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
        panel.contentView = container

        self.container = container
        self.frostedView = frostedView
        self.hostingView = hostingView
        self.panel = panel

        startSettingsSubscription()
    }

    deinit { settingsTask?.cancel() }

    private func startSettingsSubscription() {
        settingsTask = Task { [weak self] in
            guard let self else { return }
            let stream = await self.configStore.changes
            for await snapshot in stream {
                await MainActor.run { [weak self] in
                    self?.applyStyle(snapshot.popoverStyle)
                }
            }
        }
    }

    private func applyStyle(_ style: PopoverStyle) {
        frostedView.isHidden = (style != .frosty)
    }

    var isShown: Bool { panel.isVisible }
    var isFloating: Bool { floatingMode }

    func show(relativeTo anchor: NSView) {
        Task { [weak self] in
            guard let self else { return }
            let style = await self.configStore.settings.popoverStyle
            await MainActor.run { [weak self] in self?.applyStyle(style) }
        }
        if floatingMode {
            if !panel.isVisible {
                positionAnchored(to: anchor)
            }
            panel.orderFrontRegardless()
            return
        }
        positionAnchored(to: anchor)
        NSApp.activate(ignoringOtherApps: true)
        panel.orderFrontRegardless()
        installMonitors()
    }

    func present(rootView: AnyView, relativeTo anchor: NSView) {
        hostingView.rootView = rootView
        show(relativeTo: anchor)
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

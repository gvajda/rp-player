import AppKit
import SwiftUI

@MainActor
public final class UpdatePanelController: NSObject {
    private var panel: NSPanel?
    private var hosting: NSHostingView<UpdatePanelView>?
    private var localKeyMonitor: Any?
    private var globalClickMonitor: Any?

    public override init() {
        super.init()
    }

    public func show(release: ReleaseInfo) {
        if panel == nil {
            buildPanel(release: release)
        } else {
            replaceContent(release: release)
        }
        panel?.center()
        panel?.makeKeyAndOrderFront(nil)
        installKeyMonitor()
        installClickMonitor()
    }

    public func close() {
        removeKeyMonitor()
        removeClickMonitor()
        panel?.orderOut(nil)
    }

    private func buildPanel(release: ReleaseInfo) {
        let host = NSHostingView(rootView: makeView(release: release))
        host.translatesAutoresizingMaskIntoConstraints = false
        self.hosting = host

        let p = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 460, height: 540),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        p.title = "Update Available"
        p.isFloatingPanel = true
        p.level = .floating
        p.contentView = host
        self.panel = p
    }

    private func replaceContent(release: ReleaseInfo) {
        guard let hosting else { return }
        hosting.rootView = makeView(release: release)
    }

    private func makeView(release: ReleaseInfo) -> UpdatePanelView {
        UpdatePanelView(
            release: release,
            onDownloadDmg: { [weak self] url in
                NSWorkspace.shared.open(url)
                self?.close()
            },
            onViewFullNotes: { [weak self] url in
                NSWorkspace.shared.open(url)
                self?.close()
            },
            onLater: { [weak self] in
                self?.close()
            }
        )
    }

    private func installKeyMonitor() {
        guard localKeyMonitor == nil else { return }
        localKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            if event.keyCode == 53, event.window === self?.panel {
                self?.close()
                return nil
            }
            return event
        }
    }

    private func removeKeyMonitor() {
        if let m = localKeyMonitor {
            NSEvent.removeMonitor(m)
            localKeyMonitor = nil
        }
    }

    private func installClickMonitor() {
        guard globalClickMonitor == nil else { return }
        globalClickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            self?.close()
        }
    }

    private func removeClickMonitor() {
        if let m = globalClickMonitor {
            NSEvent.removeMonitor(m)
            globalClickMonitor = nil
        }
    }

    @MainActor
    deinit {
        if let m = localKeyMonitor {
            NSEvent.removeMonitor(m)
        }
        if let m = globalClickMonitor {
            NSEvent.removeMonitor(m)
        }
    }
}

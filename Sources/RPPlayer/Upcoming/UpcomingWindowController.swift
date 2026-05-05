import AppKit
import SwiftUI

@MainActor
final class UpcomingWindowController {
    private let viewModel: UpcomingProgramViewModel
    private let configStore: any ConfigStore
    private var window: NSWindow?
    private var hostingController: NSHostingController<UpcomingProgramView>?
    private var frostedView: NSVisualEffectView?
    private var settingsTask: Task<Void, Never>?

    init(viewModel: UpcomingProgramViewModel, configStore: any ConfigStore) {
        self.viewModel = viewModel
        self.configStore = configStore
    }

    deinit { settingsTask?.cancel() }

    func show() async {
        if window == nil {
            let hosting = NSHostingController(rootView: UpcomingProgramView(viewModel: viewModel))
            self.hostingController = hosting

            let container = NSView()
            container.wantsLayer = true

            let frosted = NSVisualEffectView()
            frosted.material = .hudWindow
            frosted.blendingMode = .behindWindow
            frosted.state = .active
            frosted.translatesAutoresizingMaskIntoConstraints = false
            frosted.isHidden = true
            container.addSubview(frosted)
            NSLayoutConstraint.activate([
                frosted.leadingAnchor.constraint(equalTo: container.leadingAnchor),
                frosted.trailingAnchor.constraint(equalTo: container.trailingAnchor),
                frosted.topAnchor.constraint(equalTo: container.topAnchor),
                frosted.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            ])

            hosting.view.translatesAutoresizingMaskIntoConstraints = false
            container.addSubview(hosting.view)
            NSLayoutConstraint.activate([
                hosting.view.leadingAnchor.constraint(equalTo: container.leadingAnchor),
                hosting.view.trailingAnchor.constraint(equalTo: container.trailingAnchor),
                hosting.view.topAnchor.constraint(equalTo: container.topAnchor),
                hosting.view.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            ])

            let w = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 720, height: 480),
                styleMask: [.titled, .closable, .miniaturizable, .resizable],
                backing: .buffered,
                defer: false
            )
            w.title = "Upcoming Program"
            w.minSize = NSSize(width: 480, height: 300)
            w.setFrameAutosaveName("UpcomingProgram")
            w.isReleasedWhenClosed = false
            w.contentView = container
            window = w
            frostedView = frosted
        }

        if settingsTask == nil {
            applyFrosted(await configStore.settings.frostedUpcomingEnabled)
            let stream = await configStore.changes
            settingsTask = Task { [weak self] in
                for await snapshot in stream {
                    await MainActor.run { [weak self] in
                        self?.applyFrosted(snapshot.frostedUpcomingEnabled)
                    }
                }
            }
        }

        // Shrink the window before it appears if the saved frame is wider than
        // the current filtered-channel set warrants — avoids a glitchy resize
        // visible to the user.
        if let w = window, let desired = await viewModel.desiredContentWidth() {
            let currentContent = w.contentRect(forFrameRect: w.frame).size
            if currentContent.width > desired {
                let target = max(desired, w.minSize.width)
                w.setContentSize(NSSize(width: target, height: currentContent.height))
            }
        }

        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func applyFrosted(_ enabled: Bool) {
        guard let window, let frostedView else { return }
        frostedView.isHidden = !enabled
        if enabled {
            // .behindWindow blur needs the window to be transparent; otherwise the effect view
            // samples the window's opaque backing.
            window.isOpaque = false
            window.backgroundColor = .clear
        } else {
            window.isOpaque = true
            window.backgroundColor = .windowBackgroundColor
        }
    }
}

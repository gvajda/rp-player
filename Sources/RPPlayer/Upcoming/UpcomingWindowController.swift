import AppKit
import SwiftUI

@MainActor
final class UpcomingWindowController {
    private let viewModel: UpcomingProgramViewModel
    private let configStore: any ConfigStore
    private var window: NSWindow?
    private var frostedView: NSVisualEffectView?
    private var settingsTask: Task<Void, Never>?

    init(viewModel: UpcomingProgramViewModel, configStore: any ConfigStore) {
        self.viewModel = viewModel
        self.configStore = configStore
    }

    deinit { settingsTask?.cancel() }

    func show() async {
        if window == nil {
            let rootView = UpcomingProgramView(viewModel: viewModel)
            let hosting = NSHostingController(rootView: rootView)
            let w = NSWindow(contentViewController: hosting)
            w.title = "Upcoming Program"
            w.styleMask = [.titled, .closable, .miniaturizable, .resizable]
            w.setContentSize(NSSize(width: 720, height: 480))
            w.minSize = NSSize(width: 480, height: 300)
            w.setFrameAutosaveName("UpcomingProgram")
            w.isReleasedWhenClosed = false
            window = w
        }

        if settingsTask == nil {
            await applyFrosted(await configStore.settings.frostedUpcomingEnabled)
            let stream = await configStore.changes
            settingsTask = Task { [weak self] in
                for await snapshot in stream {
                    guard let self else { return }
                    await self.applyFrosted(snapshot.frostedUpcomingEnabled)
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
        guard let window, let contentView = window.contentView else { return }
        if enabled {
            if frostedView == nil {
                let v = NSVisualEffectView()
                v.material = .hudWindow
                v.blendingMode = .behindWindow
                v.state = .active
                v.translatesAutoresizingMaskIntoConstraints = false
                contentView.addSubview(v, positioned: .below, relativeTo: contentView.subviews.first)
                NSLayoutConstraint.activate([
                    v.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
                    v.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
                    v.topAnchor.constraint(equalTo: contentView.topAnchor),
                    v.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),
                ])
                frostedView = v
            }
        } else {
            frostedView?.removeFromSuperview()
            frostedView = nil
        }
    }
}

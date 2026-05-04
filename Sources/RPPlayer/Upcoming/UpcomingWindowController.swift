import AppKit
import SwiftUI

@MainActor
final class UpcomingWindowController {
    private let viewModel: UpcomingProgramViewModel
    private var window: NSWindow?

    init(viewModel: UpcomingProgramViewModel) {
        self.viewModel = viewModel
    }

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
}

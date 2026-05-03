import AppKit
import SwiftUI

@MainActor
final class UpcomingWindowController {
    private let viewModel: UpcomingProgramViewModel
    private var window: NSWindow?

    init(viewModel: UpcomingProgramViewModel) {
        self.viewModel = viewModel
    }

    func show() {
        if window == nil {
            let rootView = UpcomingProgramView(viewModel: viewModel)
            let hosting = NSHostingController(rootView: rootView)
            let w = NSWindow(contentViewController: hosting)
            w.title = "Upcoming Program"
            w.styleMask = [.titled, .closable, .miniaturizable, .resizable]
            w.setContentSize(NSSize(width: 720, height: 480))
            w.minSize = NSSize(width: 480, height: 300)
            w.setFrameAutosaveName("UpcomingProgram")
            window = w
        }
        window?.makeKeyAndOrderFront(nil)
    }
}

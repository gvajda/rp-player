import AppKit
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private(set) var statusItemController: StatusItemController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let popover = PopoverController(rootView: AnyView(Text("RP Player")))
        statusItemController = StatusItemController(popover: popover)
    }
}

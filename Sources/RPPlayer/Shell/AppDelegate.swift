import AppKit
import Foundation
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let containerFactory: @MainActor () throws -> AppContainer
    private(set) var container: AppContainer?
    private(set) var statusItemController: StatusItemController?

    init(containerFactory: @escaping @MainActor () throws -> AppContainer = { try .live() }) {
        self.containerFactory = containerFactory
        super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.mainMenu = MainMenuBuilder.build()

        let container: AppContainer
        do {
            container = try containerFactory()
        } catch {
            preconditionFailure("AppContainer factory failed: \(error)")
        }
        self.container = container

        container.loginWindowController.onLoginSucceeded = { [weak container] in
            container?.viewModel.refreshAuthState()
            container?.settingsViewModel.refreshAuthState()
        }

        Task { await container.notificationCoordinator.start() }

        let popover = PopoverController(rootView: AnyView(MiniPlayerView(viewModel: container.viewModel)))
        statusItemController = StatusItemController(popover: popover)

        Task { await container.runOnLaunchTasks() }
    }

    func applicationWillTerminate(_ notification: Notification) {
        guard let container else { return }
        Task { await container.notificationCoordinator.stop() }

        // Block the terminate path on a clean shutdown of the coordinator —
        // libmpv must release the audio device before we exit.
        let group = DispatchGroup()
        group.enter()
        Task.detached {
            await container.shutdown()
            group.leave()
        }
        _ = group.wait(timeout: .now() + 2.0)
    }
}

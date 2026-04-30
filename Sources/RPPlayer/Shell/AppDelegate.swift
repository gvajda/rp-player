import AppKit
import Foundation
import SwiftUI
import UserNotifications

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    struct Bootstrap {
        let viewModel: MiniPlayerViewModel
        let notificationCoordinator: NotificationCoordinator
        let settingsViewModel: SettingsViewModel
        let settingsWindowController: SettingsWindowController
        let loginWindowController: LoginWindowController
        let coordinatorShutdown: @Sendable () async -> Void
    }

    private(set) var statusItemController: StatusItemController?
    private(set) var viewModel: MiniPlayerViewModel?
    private(set) var notificationCoordinator: NotificationCoordinator?
    private(set) var settingsViewModel: SettingsViewModel?
    private(set) var settingsWindowController: SettingsWindowController?
    private(set) var loginWindowController: LoginWindowController?
    private var coordinatorShutdown: (@Sendable () async -> Void)?
    private let bootstrap: () -> Bootstrap

    convenience override init() {
        self.init(bootstrap: AppDelegate.realBootstrap)
    }

    init(bootstrap: @escaping () -> Bootstrap) {
        self.bootstrap = bootstrap
        super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        let result = bootstrap()
        self.viewModel = result.viewModel
        self.notificationCoordinator = result.notificationCoordinator
        self.settingsViewModel = result.settingsViewModel
        self.settingsWindowController = result.settingsWindowController
        self.loginWindowController = result.loginWindowController
        self.coordinatorShutdown = result.coordinatorShutdown

        result.loginWindowController.onLoginSucceeded = { [weak self] in
            self?.viewModel?.refreshAuthState()
            self?.settingsViewModel?.refreshAuthState()
        }

        Task { await result.notificationCoordinator.start() }

        let popover = PopoverController(rootView: AnyView(MiniPlayerView(viewModel: result.viewModel)))
        statusItemController = StatusItemController(popover: popover)
    }

    func applicationWillTerminate(_ notification: Notification) {
        Task { await self.notificationCoordinator?.stop() }

        guard let shutdown = coordinatorShutdown else { return }
        // Block the terminate path on a clean shutdown of the coordinator —
        // libmpv must release the audio device before we exit.
        let group = DispatchGroup()
        group.enter()
        Task.detached {
            await shutdown()
            group.leave()
        }
        _ = group.wait(timeout: .now() + 2.0)
    }

    private static func realBootstrap() -> Bootstrap {
        let container: AppContainer
        do {
            container = try AppContainer.live()
        } catch {
            preconditionFailure("AppContainer.live() failed: \(error)")
        }
        Task { await container.runOnLaunchTasks() }
        return Bootstrap(
            viewModel: container.viewModel,
            notificationCoordinator: container.notificationCoordinator,
            settingsViewModel: container.settingsViewModel,
            settingsWindowController: container.settingsWindowController,
            loginWindowController: container.loginWindowController,
            coordinatorShutdown: { await container.shutdown() }
        )
    }
}

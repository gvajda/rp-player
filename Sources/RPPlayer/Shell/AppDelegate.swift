import AppKit
import Foundation
import SwiftUI
import UserNotifications

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let containerFactory: @MainActor () throws -> AppContainer
    private(set) var container: AppContainer?
    private(set) var statusItemController: StatusItemController?
    // delegate is weak so AppDelegate holds a strong ref
    private(set) var notificationClickRouter: NotificationClickRouter?

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

        // Start the view model now (rather than lazily from MiniPlayerView.task)
        // so the menu-bar tooltip and right-click menu reflect live state before
        // the popover has ever been opened. start() is idempotent.
        Task { await container.viewModel.start() }

        let popover = PopoverController(rootView: AnyView(MiniPlayerView(viewModel: container.viewModel)))
        let statusItemController = StatusItemController(
            popover: popover,
            menuProvider: { [weak container] in
                ContextMenuBuilder.build(viewModel: container?.viewModel)
            },
            remainingSecondsProvider: { [weak container] in
                container?.viewModel.remainingSecondsForTooltip
            }
        )
        self.statusItemController = statusItemController

        container.viewModel.showPopoverIfNeeded = { [weak statusItemController] in
            statusItemController?.showPopoverIfNeeded()
        }

        if Bundle.main.bundleIdentifier != nil && Bundle.main.bundleURL.pathExtension == "app" {
            let router = NotificationClickRouter(
                coordinator: container.coordinator,
                registry: container.songRegistry,
                api: container.api,
                mainPresenter: { [weak statusItemController, container] in
                    container.pastSongPopoverController.close()
                    statusItemController?.showPopoverIfNeeded()
                },
                pastSongPresenter: { [weak statusItemController, container] song in
                    statusItemController?.closeIfShown()
                    guard let anchor = statusItemController?.statusItem.button else { return }
                    let viewModel = PastSongViewModel(
                        song: song,
                        albumArtCache: container.albumArtCache,
                        auth: container.keychainAuth,
                        api: container.api
                    )
                    container.pastSongPopoverController.present(viewModel: viewModel, relativeTo: anchor)
                }
            )
            self.notificationClickRouter = router
            UNUserNotificationCenter.current().delegate = router
        }

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

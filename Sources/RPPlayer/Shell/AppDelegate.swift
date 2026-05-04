import AppKit
import Foundation
import SwiftUI
import UserNotifications

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let containerFactory: @MainActor () throws -> AppContainer
    private(set) var container: AppContainer?
    private(set) var statusItemController: StatusItemController?
    private(set) var popover: PopoverController?
    private var floatingModeBinderTask: Task<Void, Never>?
    // delegate is weak so AppDelegate holds a strong ref
    private(set) var notificationClickRouter: NotificationClickRouter?
    // Owned here so we can stop subscriptions on transitions. Outside-click /
    // Esc dismissal of the past-song popover does not stop this VM eagerly —
    // it stops on the next interaction (new past-song click, or main popover open).
    private var pastSongViewModel: PastSongViewModel?

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
        container.nowPlayingCenterController.start()

        // Start the view model now (rather than lazily from MiniPlayerView.task)
        // so the menu-bar tooltip and right-click menu reflect live state before
        // the popover has ever been opened. start() is idempotent.
        Task { await container.viewModel.start() }

        let popover = PopoverController(rootView: AnyView(MiniPlayerView(viewModel: container.viewModel)))
        self.popover = popover
        let statusItemController = StatusItemController(
            popover: popover,
            menuProvider: { [weak container] in
                ContextMenuBuilder.build(viewModel: container?.viewModel)
            },
            remainingSecondsProvider: { [weak container] in
                container?.viewModel.remainingSecondsForTooltip
            },
            initialIconStyle: container.initialMenuBarIconStyle
        )
        self.statusItemController = statusItemController

        // Apply current floating-mode setting and keep popover in sync with
        // future menu-toggle changes. The changes stream yields the current
        // snapshot first so this handles both initial launch and updates.
        floatingModeBinderTask?.cancel()
        floatingModeBinderTask = Task { @MainActor [weak self, weak container] in
            guard let store = container?.configStore else { return }
            var lastIconStyle: MenuBarIconStyle?
            for await snapshot in await store.changes {
                guard let self else { return }
                let wantsFloating = snapshot.popoverFloating
                let currently = self.popover?.isFloating ?? false
                if wantsFloating != currently {
                    self.popover?.setFloatingMode(wantsFloating)
                    if wantsFloating, let button = self.statusItemController?.statusItem.button {
                        self.popover?.show(relativeTo: button)
                    }
                }
                if snapshot.menuBarIconStyle != lastIconStyle {
                    lastIconStyle = snapshot.menuBarIconStyle
                    self.statusItemController?.setIconStyle(snapshot.menuBarIconStyle)
                }
            }
        }

        container.viewModel.showPopoverIfNeeded = { [weak statusItemController] in
            statusItemController?.showPopoverIfNeeded()
        }

        if Bundle.main.bundleIdentifier != nil && Bundle.main.bundleURL.pathExtension == "app" {
            let router = NotificationClickRouter(
                coordinator: container.coordinator,
                registry: container.songRegistry,
                api: container.api,
                mainPresenter: { [weak self, weak statusItemController, container] in
                    self?.pastSongViewModel?.stop()
                    self?.pastSongViewModel = nil
                    container.pastSongPopoverController.close()
                    statusItemController?.showPopoverIfNeeded()
                },
                pastSongPresenter: { [weak self, weak statusItemController, container] song in
                    statusItemController?.closeIfShown()
                    guard let anchor = statusItemController?.statusItem.button else { return }
                    self?.pastSongViewModel?.stop()
                    let viewModel = PastSongViewModel(
                        song: song,
                        albumArtCache: container.albumArtCache,
                        auth: container.keychainAuth,
                        api: container.api,
                        configStore: container.configStore,
                        paletteExtractor: AmbientPaletteExtractor()
                    )
                    self?.pastSongViewModel = viewModel
                    container.pastSongPopoverController.present(
                        rootView: AnyView(PastSongView(viewModel: viewModel)),
                        relativeTo: anchor
                    )
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
        container.nowPlayingCenterController.stop()

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

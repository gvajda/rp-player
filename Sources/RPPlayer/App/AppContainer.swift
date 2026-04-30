import Foundation

@MainActor
final class AppContainer {
    let viewModel: MiniPlayerViewModel
    let notificationCoordinator: NotificationCoordinator
    let settingsViewModel: SettingsViewModel
    let settingsWindowController: SettingsWindowController
    let loginWindowController: LoginWindowController

    private let coordinatorShutdown: @Sendable () async -> Void
    private let onLaunchTasksClosures: [@Sendable () async -> Void]

    init(
        viewModel: MiniPlayerViewModel,
        notificationCoordinator: NotificationCoordinator,
        settingsViewModel: SettingsViewModel,
        settingsWindowController: SettingsWindowController,
        loginWindowController: LoginWindowController,
        coordinatorShutdown: @escaping @Sendable () async -> Void,
        onLaunchTasks: [@Sendable () async -> Void] = []
    ) {
        self.viewModel = viewModel
        self.notificationCoordinator = notificationCoordinator
        self.settingsViewModel = settingsViewModel
        self.settingsWindowController = settingsWindowController
        self.loginWindowController = loginWindowController
        self.coordinatorShutdown = coordinatorShutdown
        self.onLaunchTasksClosures = onLaunchTasks
    }

    func shutdown() async {
        await coordinatorShutdown()
    }

    func runOnLaunchTasks() async {
        for task in onLaunchTasksClosures {
            await task()
        }
    }
}

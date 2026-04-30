import XCTest
@testable import RPPlayer

private actor ShutdownFlag {
    private(set) var fired = false
    func mark() { fired = true }
}

private actor LaunchTaskCounter {
    private(set) var count = 0
    func increment() { count += 1 }
}

@MainActor
final class AppContainerTests: XCTestCase {
    private func makeStubContainer(
        coordinatorShutdown: @escaping @Sendable () async -> Void = {},
        onLaunchTasks: [@Sendable () async -> Void] = []
    ) -> (AppContainer, MockPlaybackCoordinator, MiniPlayerViewModel, SettingsViewModel) {
        let coordinator = MockPlaybackCoordinator()
        let api = MockRpApiClient()
        let cache = StubAlbumArtCache()
        let service = MockNotificationService()
        let auth = StubKeychainAuth()
        let configStore = StubConfigStore(initial: .default)
        let deviceCatalog = StubAudioDeviceCatalog(initial: [])
        let viewModel = MiniPlayerViewModel(
            coordinator: coordinator, api: api, initialChannelId: 0,
            albumArtCache: cache, auth: auth, openSettings: { }
        )
        let notificationCoordinator = NotificationCoordinator(
            coordinator: coordinator, cache: cache, service: service,
            notificationsEnabled: { false },
            channelTitle: { _ in nil },
            cachedFileURL: { _ in nil }
        )
        let settingsViewModel = SettingsViewModel(
            configStore: configStore, deviceCatalog: deviceCatalog, auth: auth,
            openLoginWindow: { }, openApplicationData: { }
        )
        let settingsWindowController = SettingsWindowController(viewModel: settingsViewModel)
        let loginWindowController = LoginWindowController(keychainAuth: auth)
        let container = AppContainer(
            viewModel: viewModel,
            notificationCoordinator: notificationCoordinator,
            settingsViewModel: settingsViewModel,
            settingsWindowController: settingsWindowController,
            loginWindowController: loginWindowController,
            coordinatorShutdown: coordinatorShutdown,
            onLaunchTasks: onLaunchTasks
        )
        return (container, coordinator, viewModel, settingsViewModel)
    }

    func testDesignatedInitExposesInjectedCollaborators() async throws {
        let (container, _, viewModel, settingsViewModel) = makeStubContainer()
        XCTAssertTrue(container.viewModel === viewModel)
        XCTAssertTrue(container.settingsViewModel === settingsViewModel)
        XCTAssertNotNil(container.notificationCoordinator)
        XCTAssertNotNil(container.settingsWindowController)
        XCTAssertNotNil(container.loginWindowController)
    }

    func testShutdownInvokesInjectedClosure() async throws {
        let flag = ShutdownFlag()
        let (container, _, _, _) = makeStubContainer(
            coordinatorShutdown: { await flag.mark() }
        )

        await container.shutdown()

        let fired = await flag.fired
        XCTAssertTrue(fired)
    }

    func testRunOnLaunchTasksAwaitsAllInjectedClosures() async throws {
        let counter = LaunchTaskCounter()
        let (container, _, _, _) = makeStubContainer(
            onLaunchTasks: [
                { await counter.increment() },
                { await counter.increment() },
            ]
        )

        await container.runOnLaunchTasks()

        let count = await counter.count
        XCTAssertEqual(count, 2)
    }

    func testRunOnLaunchTasksWithEmptyArrayReturnsImmediately() async throws {
        let (container, _, _, _) = makeStubContainer(onLaunchTasks: [])
        await container.runOnLaunchTasks()
    }
}

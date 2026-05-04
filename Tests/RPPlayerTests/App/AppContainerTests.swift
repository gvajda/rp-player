import SwiftUI
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

private actor AsyncSemaphore {
    private var permits: Int
    private var waiters: [CheckedContinuation<Void, Never>] = []

    init(value: Int) { self.permits = value }

    func signal() {
        if let cont = waiters.first {
            waiters.removeFirst()
            cont.resume()
        } else {
            permits += 1
        }
    }

    func wait() async {
        if permits > 0 {
            permits -= 1
            return
        }
        await withCheckedContinuation { cont in
            waiters.append(cont)
        }
    }
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
            albumArtCache: cache, auth: auth,
            configStore: configStore,
            paletteExtractor: StubAmbientPaletteExtractor(),
            openSettings: { }
        )
        let notificationCoordinator = NotificationCoordinator(
            coordinator: coordinator, cache: cache, service: service,
            registry: SongRegistry(),
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
            songRegistry: SongRegistry(),
            coordinator: coordinator,
            api: api,
            albumArtCache: cache,
            keychainAuth: auth,
            pastSongPopoverController: PopoverController(rootView: AnyView(EmptyView())),
            upcomingWindowController: UpcomingWindowController(
                viewModel: UpcomingProgramViewModel(
                    api: MockRpApiClient(),
                    albumArtCache: StubAlbumArtCache(),
                    configStore: StubConfigStore(initial: .default),
                    paletteExtractor: StubAmbientPaletteExtractor()
                )
            ),
            configStore: configStore,
            nowPlayingCenterController: NowPlayingCenterController(
                coordinator: coordinator, albumArtCache: cache
            ),
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

    func testRunOnLaunchTasksRunsClosuresConcurrently() async throws {
        let counter = LaunchTaskCounter()
        let started = AsyncSemaphore(value: 0)
        let canFinish = AsyncSemaphore(value: 0)

        let (container, _, _, _) = makeStubContainer(
            onLaunchTasks: [
                {
                    await started.signal()
                    await canFinish.wait()
                    await counter.increment()
                },
                {
                    await started.signal()
                    await canFinish.wait()
                    await counter.increment()
                },
            ]
        )

        let runTask = Task { await container.runOnLaunchTasks() }

        await started.wait()
        await started.wait()

        await canFinish.signal()
        await canFinish.signal()

        await runTask.value
        let count = await counter.count
        XCTAssertEqual(count, 2)
    }

    func testGeneratePlayerIdMatchesRp3UuidShape() {
        let id = AppContainer.generatePlayerId()
        let pattern = "^rp3_[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$"
        XCTAssertNotNil(id.range(of: pattern, options: .regularExpression),
                        "playerId '\(id)' does not match rp3_<8-4-4-4-12 hex> shape")
    }

    func testGeneratePlayerIdProducesUniqueValues() {
        let a = AppContainer.generatePlayerId()
        let b = AppContainer.generatePlayerId()
        XCTAssertNotEqual(a, b)
    }
}

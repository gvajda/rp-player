import AppKit
import XCTest
@testable import RPPlayer

@MainActor
final class AppDelegateTests: XCTestCase {
    private var delegate: AppDelegate!
    private var coordinator: MockPlaybackCoordinator!

    override func setUp() async throws {
        coordinator = MockPlaybackCoordinator()
        let coordinator = self.coordinator!
        delegate = AppDelegate(containerFactory: {
            let api = MockRpApiClient()
            let cache = StubAlbumArtCache()
            let service = MockNotificationService()
            let auth = StubKeychainAuth()
            let configStore = StubConfigStore(initial: .default)
            let deviceCatalog = StubAudioDeviceCatalog(initial: [])
            let viewModel = MiniPlayerViewModel(
                coordinator: coordinator,
                api: api,
                initialChannelId: 0,
                albumArtCache: cache,
                auth: auth,
                openSettings: { }
            )
            let notificationCoordinator = NotificationCoordinator(
                coordinator: coordinator,
                cache: cache,
                service: service,
                registry: SongRegistry(),
                notificationsEnabled: { false },
                channelTitle: { _ in nil },
                cachedFileURL: { _ in nil }
            )
            let settingsViewModel = SettingsViewModel(
                configStore: configStore,
                deviceCatalog: deviceCatalog,
                auth: auth,
                openLoginWindow: { },
                openApplicationData: { }
            )
            let settingsWindowController = SettingsWindowController(viewModel: settingsViewModel)
            let loginWindowController = LoginWindowController(keychainAuth: auth)
            return AppContainer(
                viewModel: viewModel,
                notificationCoordinator: notificationCoordinator,
                settingsViewModel: settingsViewModel,
                settingsWindowController: settingsWindowController,
                loginWindowController: loginWindowController,
                coordinatorShutdown: { await coordinator.shutdown() },
                onLaunchTasks: []
            )
        })
    }

    override func tearDown() async throws {
        if let item = delegate?.statusItemController?.statusItem {
            NSStatusBar.system.removeStatusItem(item)
        }
        delegate = nil
        coordinator = nil
    }

    func testApplicationDidFinishLaunchingCreatesStatusItemControllerAndViewModel() {
        XCTAssertNil(delegate.statusItemController)
        XCTAssertNil(delegate.container)
        delegate.applicationDidFinishLaunching(Notification(name: NSApplication.didFinishLaunchingNotification))
        XCTAssertNotNil(delegate.statusItemController)
        XCTAssertNotNil(delegate.container)
        XCTAssertNotNil(delegate.container?.viewModel)
    }

    func testApplicationDidFinishLaunchingInstallsMainMenu() async throws {
        NSApp.mainMenu = nil
        delegate.applicationDidFinishLaunching(
            Notification(name: NSApplication.didFinishLaunchingNotification)
        )
        let menu = try XCTUnwrap(NSApp.mainMenu)
        XCTAssertEqual(menu.items.count, 2)
        XCTAssertEqual(menu.items.first?.submenu?.title, ProcessInfo.processInfo.processName)
    }

    func testApplicationWillTerminateInvokesShutdown() async throws {
        let didShutDown = AsyncSignal()
        delegate = AppDelegate(containerFactory: {
            let coordinator = MockPlaybackCoordinator()
            let api = MockRpApiClient()
            let cache = StubAlbumArtCache()
            let service = MockNotificationService()
            let auth = StubKeychainAuth()
            let configStore = StubConfigStore(initial: .default)
            let deviceCatalog = StubAudioDeviceCatalog(initial: [])
            let viewModel = MiniPlayerViewModel(
                coordinator: coordinator, api: api, initialChannelId: 0, albumArtCache: cache,
                auth: auth, openSettings: { }
            )
            let notificationCoordinator = NotificationCoordinator(
                coordinator: coordinator, cache: cache, service: service,
                registry: SongRegistry(),
                notificationsEnabled: { false }, channelTitle: { _ in nil }, cachedFileURL: { _ in nil }
            )
            let settingsViewModel = SettingsViewModel(
                configStore: configStore, deviceCatalog: deviceCatalog, auth: auth,
                openLoginWindow: { }, openApplicationData: { }
            )
            let settingsWindowController = SettingsWindowController(viewModel: settingsViewModel)
            let loginWindowController = LoginWindowController(keychainAuth: auth)
            return AppContainer(
                viewModel: viewModel,
                notificationCoordinator: notificationCoordinator,
                settingsViewModel: settingsViewModel,
                settingsWindowController: settingsWindowController,
                loginWindowController: loginWindowController,
                coordinatorShutdown: { didShutDown.signal() },
                onLaunchTasks: []
            )
        })
        delegate.applicationDidFinishLaunching(Notification(name: NSApplication.didFinishLaunchingNotification))
        delegate.applicationWillTerminate(Notification(name: NSApplication.willTerminateNotification))
        let signaled = await didShutDown.wait(timeout: .seconds(2))
        XCTAssertTrue(signaled)
    }
}

final class AsyncSignal: @unchecked Sendable {
    private let lock = NSLock()
    private var continuations: [CheckedContinuation<Void, Never>] = []
    private var fired = false

    func signal() {
        lock.lock()
        fired = true
        let pending = continuations
        continuations.removeAll()
        lock.unlock()
        pending.forEach { $0.resume() }
    }

    func wait(timeout: Duration) async -> Bool {
        await withTaskGroup(of: Bool.self) { group in
            group.addTask {
                await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
                    self.lock.lock()
                    if self.fired {
                        self.lock.unlock()
                        c.resume()
                    } else {
                        self.continuations.append(c)
                        self.lock.unlock()
                    }
                }
                return true
            }
            group.addTask {
                try? await Task.sleep(for: timeout)
                return false
            }
            let result = await group.next() ?? false
            group.cancelAll()
            return result
        }
    }
}

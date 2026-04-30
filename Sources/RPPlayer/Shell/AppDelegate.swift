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
        let logger = AppLogger.fileBacked(category: "shell", directory: ConfigPaths.logsDirectory)
        let configURL = ConfigPaths.configFile
        let initial = Self.loadSettings(from: configURL)
        let store: JSONConfigStore?
        do {
            store = try JSONConfigStore(url: configURL)
        } catch {
            logger.error("Failed to open config store: \(error.localizedDescription)")
            store = nil
        }

        let keychainAuth = KeychainCookieProvider()
        let api = LiveRpApiClient(cookieProvider: keychainAuth, logger: logger)

        let imageBaseURL = URL(string: "https://img.radioparadise.com/")!
        let cache: any AlbumArtCache
        do {
            cache = try LiveAlbumArtCache(
                directory: ConfigPaths.albumArtCacheDirectory,
                baseURL: imageBaseURL,
                logger: logger
            )
        } catch {
            logger.error("Failed to open album art cache: \(error.localizedDescription)")
            cache = NoopAlbumArtCache()
        }

        let engine: any PlayerEngine
        do {
            engine = try LibmpvPlayerEngine()
        } catch {
            // Keep the menu-bar shell up so the user can see the error banner
            // even when libmpv fails to initialise (missing dylib, audio-device
            // contention, etc.).
            engine = NoopPlayerEngine(error: error)
        }

        let coordinator = LivePlaybackCoordinator(
            api: api,
            engine: engine,
            logger: logger,
            bitrate: initial.bitrate,
            onHogModeFallback: { [store] in
                guard let store else { return }
                try? await store.update { $0.hogModeEnabled = false }
            }
        )

        // Bridge persistent audio settings → engine. The stream yields the
        // current snapshot first, so initial hog-mode + device UID get applied
        // before the user ever opens the popover. Subsequent settings changes
        // propagate on every save. mpv applies these on next file-load, so
        // toggling mid-playback requires a stop/play to take effect.
        if let store {
            Task { [engine] in
                let stream = await store.changes
                for await settings in stream {
                    try? await engine.setHogMode(settings.hogModeEnabled)
                    try? await engine.setOutputDevice(uid: settings.outputDeviceUID)
                }
            }
        }

        let deviceCatalog = CoreAudioDeviceCatalog(lister: CoreAudioDeviceLister())

        // UNUserNotificationCenter.current() throws on unbundled processes
        // (no main bundle proxy). PR 12 ships the .app; until then `swift run`
        // gets a no-op service so the rest of the wiring still constructs.
        let notificationService: any NotificationService =
            Bundle.main.bundleIdentifier != nil
                ? LiveNotificationService(center: UNUserNotificationCenter.current())
                : NoopNotificationService()
        let notificationCoordinator = NotificationCoordinator(
            coordinator: coordinator,
            cache: cache,
            service: notificationService,
            notificationsEnabled: { [store] in
                guard let store else { return false }
                return await store.settings.notificationsEnabled
            },
            channelTitle: { [api] channelId in
                guard let channels = try? await api.listChannels() else { return nil }
                return channels.first(where: { Int($0.chan) == channelId })?.title
            },
            cachedFileURL: { [cache] coverPath in
                await cache.fileURL(for: coverPath)
            }
        )

        let loginWindowController = LoginWindowController(keychainAuth: keychainAuth)

        let settingsViewModel = SettingsViewModel(
            configStore: store ?? NoopConfigStore(),
            deviceCatalog: deviceCatalog,
            auth: keychainAuth,
            openLoginWindow: { [loginWindowController] in loginWindowController.show() },
            openApplicationData: {
                try? FileManager.default.createDirectory(
                    at: ConfigPaths.applicationSupportRoot, withIntermediateDirectories: true
                )
                NSWorkspace.shared.open(ConfigPaths.applicationSupportRoot)
            }
        )

        let settingsWindowController = SettingsWindowController(viewModel: settingsViewModel)

        let viewModel = MiniPlayerViewModel(
            coordinator: coordinator,
            api: api,
            initialChannelId: initial.selectedChannelId,
            albumArtCache: cache,
            auth: keychainAuth,
            openSettings: { [settingsWindowController] in settingsWindowController.show() },
            persistChannelId: { id in
                guard let store else { return }
                try? await store.update { $0.selectedChannelId = id }
            }
        )

        Task {
            // Best-effort authorization request; fails silently in unbundled processes.
            _ = try? await notificationService.requestAuthorization()
        }

        Task { @MainActor [viewModel, settingsViewModel] in
            // Validate stored auth on launch: if RP no longer accepts the cookie
            // (server returns anonymous or 401), clear keychain so the UI doesn't
            // claim "signed in" when the next rate call would 401.
            await StartupAuthProbe.run(api: api, auth: keychainAuth) {
                viewModel.refreshAuthState()
                settingsViewModel.refreshAuthState()
            }
        }

        return Bootstrap(
            viewModel: viewModel,
            notificationCoordinator: notificationCoordinator,
            settingsViewModel: settingsViewModel,
            settingsWindowController: settingsWindowController,
            loginWindowController: loginWindowController,
            coordinatorShutdown: { await coordinator.shutdown() }
        )
    }

    private static func loadSettings(from url: URL) -> AppSettings {
        guard let data = try? Data(contentsOf: url),
              let settings = try? JSONDecoder().decode(AppSettings.self, from: data)
        else { return .default }
        return settings
    }
}

// Fallback when JSONConfigStore fails to open so SettingsViewModel still constructs.
private final class NoopConfigStore: ConfigStore {
    var settings: AppSettings { .default }
    var changes: AsyncStream<AppSettings> { AsyncStream { $0.finish() } }
    func update(_ mutate: @Sendable (inout AppSettings) -> Void) async throws {}
}

private struct NoopNotificationService: NotificationService {
    func requestAuthorization() async throws -> Bool { false }
    func notify(title: String, subtitle: String, attachmentURL: URL?) async throws {}
}

private struct NoopAlbumArtCache: AlbumArtCache {
    func image(for coverPath: String) async -> NSImage? { nil }
}

private struct NoopPlayerEngine: PlayerEngine {
    let error: Error
    var events: AsyncStream<PlayerEvent> { AsyncStream { $0.finish() } }
    func play(url: URL) async throws { throw error }
    func pause() async throws { throw error }
    func resume() async throws { throw error }
    func stop() async throws { throw error }
    func seek(to seconds: Double) async throws { throw error }
    func setHogMode(_ enabled: Bool) async throws { throw error }
    func setOutputDevice(uid: String?) async throws { throw error }
    func shutdown() async {}
}

import AppKit
import Foundation
import Security
import UserNotifications

@MainActor
final class AppContainer {
    let viewModel: MiniPlayerViewModel
    let notificationCoordinator: NotificationCoordinator
    let settingsViewModel: SettingsViewModel
    let settingsWindowController: SettingsWindowController
    let loginWindowController: LoginWindowController
    let songRegistry: SongRegistry
    let coordinator: any PlaybackCoordinator
    let api: any RpApiClient
    let albumArtCache: any AlbumArtCache
    let keychainAuth: any KeychainAuth
    let pastSongPopoverController: PastSongPopoverController
    let upcomingWindowController: UpcomingWindowController

    private let coordinatorShutdown: @Sendable () async -> Void
    private let onLaunchTasksClosures: [@Sendable () async -> Void]

    init(
        viewModel: MiniPlayerViewModel,
        notificationCoordinator: NotificationCoordinator,
        settingsViewModel: SettingsViewModel,
        settingsWindowController: SettingsWindowController,
        loginWindowController: LoginWindowController,
        songRegistry: SongRegistry,
        coordinator: any PlaybackCoordinator,
        api: any RpApiClient,
        albumArtCache: any AlbumArtCache,
        keychainAuth: any KeychainAuth,
        pastSongPopoverController: PastSongPopoverController,
        upcomingWindowController: UpcomingWindowController,
        coordinatorShutdown: @escaping @Sendable () async -> Void,
        onLaunchTasks: [@Sendable () async -> Void] = []
    ) {
        self.viewModel = viewModel
        self.notificationCoordinator = notificationCoordinator
        self.settingsViewModel = settingsViewModel
        self.settingsWindowController = settingsWindowController
        self.loginWindowController = loginWindowController
        self.songRegistry = songRegistry
        self.coordinator = coordinator
        self.api = api
        self.albumArtCache = albumArtCache
        self.keychainAuth = keychainAuth
        self.pastSongPopoverController = pastSongPopoverController
        self.upcomingWindowController = upcomingWindowController
        self.coordinatorShutdown = coordinatorShutdown
        self.onLaunchTasksClosures = onLaunchTasks
    }

    func shutdown() async {
        await coordinatorShutdown()
    }

    func runOnLaunchTasks() async {
        await withTaskGroup(of: Void.self) { group in
            for task in onLaunchTasksClosures {
                group.addTask {
                    await task()
                }
            }
        }
    }
}

extension AppContainer {
    static func live() throws -> AppContainer {
        let logger = AppLogger.fileBacked(category: "shell", directory: ConfigPaths.logsDirectory)
        logger.info("AppContainer.live() starting")
        let configURL = ConfigPaths.configFile
        let initial = Self.loadSettings(from: configURL)
        logger.setVerbose(initial.verboseLoggingEnabled)
        logger.info("loaded settings: hog=\(initial.hogModeEnabled) device=\(initial.outputDeviceUID ?? "nil") bitrate=\(initial.bitrate) verboseLogging=\(initial.verboseLoggingEnabled)")
        let store: JSONConfigStore?
        do {
            store = try JSONConfigStore(url: configURL)
        } catch {
            logger.error("Failed to open config store: \(error.localizedDescription)")
            store = nil
        }

        let playerId: String
        if let existing = initial.playerId, !existing.isEmpty {
            playerId = existing
            logger.info("player_id=\(playerId) (loaded)")
        } else {
            playerId = Self.generatePlayerId()
            logger.info("player_id=\(playerId) (newly generated)")
            if let store {
                Task { try? await store.update { $0.playerId = playerId } }
            }
        }

        let keychainAuth = KeychainCookieProvider()
        let api = LiveRpApiClient(cookieProvider: keychainAuth, playerId: playerId, logger: logger)

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
            engine = try MpvPlayerEngine(
                initialDeviceUID: initial.outputDeviceUID,
                logger: logger
            )
        } catch {
            // Keep the menu-bar shell up so the user can see the error banner
            // even when libmpv fails to initialise (missing dylib, audio-device
            // contention, etc.).
            engine = NoopPlayerEngine(error: error)
        }

        let hogController = HogModeController()
        if initial.hogModeEnabled, let uid = initial.outputDeviceUID, !uid.isEmpty {
            Task { _ = await hogController.acquire(deviceUID: uid) }
        }

        let coordinator = LivePlaybackCoordinator(
            api: api,
            engine: engine,
            logger: logger,
            // Pull-based: every play/skip/prefetch reads the live bitrate from the
            // store. Avoids any push-binder race where a stale bitrate could be in
            // flight when the user changes channels.
            bitrateProvider: { [store] in
                guard let store else { return initial.bitrate }
                return await store.settings.bitrate
            },
            prefetchArt: { [cache] cover in
                Task.detached { _ = await cache.image(for: cover) }
            }
        )

        // Bridge persistent audio settings → engine. The stream yields the
        // current snapshot first, so initial hog-mode + device UID get applied
        // before the user ever opens the popover. Subsequent settings changes
        // propagate on every save. mpv applies these on next file-load, so
        // toggling mid-playback requires a stop/play to take effect.
        if let store {
            Task { [engine, hogController] in
                let stream = await store.changes
                for await settings in stream {
                    if settings.hogModeEnabled, let uid = settings.outputDeviceUID, !uid.isEmpty {
                        _ = await hogController.acquire(deviceUID: uid)
                    } else {
                        await hogController.release()
                    }
                    try? await engine.setOutputDevice(uid: settings.outputDeviceUID)
                }
            }
            Task { [logger] in
                let stream = await store.changes
                for await settings in stream {
                    logger.setVerbose(settings.verboseLoggingEnabled)
                }
            }
            Task { @MainActor in
                let stream = await store.changes
                for await settings in stream {
                    switch settings.appearance {
                    case .system: NSApp.appearance = nil
                    case .light:  NSApp.appearance = NSAppearance(named: .aqua)
                    case .dark:   NSApp.appearance = NSAppearance(named: .darkAqua)
                    }
                }
            }
        }

        let deviceCatalog = CoreAudioDeviceCatalog(lister: CoreAudioDeviceLister())

        // UNUserNotificationCenter.current() throws on unbundled processes
        // (no main bundle proxy). PR 12 ships the .app; until then `swift run`
        // gets a no-op service so the rest of the wiring still constructs.
        let bundleId = Bundle.main.bundleIdentifier
        logger.info("notification setup: Bundle.main.bundleIdentifier=\(bundleId ?? "nil")")
        let notificationService: any NotificationService =
            bundleId != nil
                ? LiveNotificationService(center: UNUserNotificationCenter.current())
                : NoopNotificationService()
        logger.info("notification service: \(bundleId != nil ? "Live" : "Noop")")

        let songRegistry = SongRegistry(capacity: 100)
        let notificationCoordinator = NotificationCoordinator(
            coordinator: coordinator,
            cache: cache,
            service: notificationService,
            registry: songRegistry,
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
            },
            listChannels: { [api] in try await api.listChannels() }
        )

        let settingsWindowController = SettingsWindowController(viewModel: settingsViewModel)

        let viewModel = MiniPlayerViewModel(
            coordinator: coordinator,
            api: api,
            initialChannelId: initial.selectedChannelId,
            albumArtCache: cache,
            auth: keychainAuth,
            configStore: store ?? NoopConfigStore(),
            paletteExtractor: AmbientPaletteExtractor(),
            openSettings: { [settingsWindowController] in settingsWindowController.show() },
            persistChannelId: { id in
                guard let store else { return }
                try? await store.update { $0.selectedChannelId = id }
            }
        )

        let upcomingViewModel = UpcomingProgramViewModel(
            api: api,
            albumArtCache: cache,
            configStore: store ?? NoopConfigStore(),
            paletteExtractor: AmbientPaletteExtractor()
        )
        let upcomingWindowController = UpcomingWindowController(viewModel: upcomingViewModel)
        viewModel.upcomingAction = { [upcomingWindowController] in upcomingWindowController.show() }

        let onLaunchTasks: [@Sendable () async -> Void] = [
            { [logger] in
                do {
                    let granted = try await notificationService.requestAuthorization()
                    logger.info("notification authorization: granted=\(granted)")
                } catch {
                    logger.error("notification authorization failed: \(String(describing: error))")
                }
            },
            { @MainActor in
                await StartupAuthProbe.run(api: api, auth: keychainAuth, logger: logger) {
                    viewModel.refreshAuthState()
                    settingsViewModel.refreshAuthState()
                }
            }
        ]

        logger.info("AppContainer.live() ready")
        return AppContainer(
            viewModel: viewModel,
            notificationCoordinator: notificationCoordinator,
            settingsViewModel: settingsViewModel,
            settingsWindowController: settingsWindowController,
            loginWindowController: loginWindowController,
            songRegistry: songRegistry,
            coordinator: coordinator,
            api: api,
            albumArtCache: cache,
            keychainAuth: keychainAuth,
            pastSongPopoverController: PastSongPopoverController(),
            upcomingWindowController: upcomingWindowController,
            coordinatorShutdown: { await coordinator.shutdown(); await hogController.release() },
            onLaunchTasks: onLaunchTasks
        )
    }

    private static func loadSettings(from url: URL) -> AppSettings {
        guard let data = try? Data(contentsOf: url),
              let settings = try? JSONDecoder().decode(AppSettings.self, from: data)
        else { return .default }
        return settings
    }

    static func generatePlayerId() -> String {
        var bytes = [UInt8](repeating: 0, count: 16)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        let hex = bytes.map { String(format: "%02x", $0) }.joined()
        let s = Array(hex)
        let part = { (start: Int, len: Int) in String(s[start..<start+len]) }
        return "rp3_\(part(0,8))-\(part(8,4))-\(part(12,4))-\(part(16,4))-\(part(20,12))"
    }
}

// Fallback when JSONConfigStore fails to open so SettingsViewModel still constructs.
private final class NoopConfigStore: ConfigStore {
    var settings: AppSettings { .default }
    var changes: AsyncStream<AppSettings> { AsyncStream { $0.finish() } }
    func update(_ mutate: @Sendable (inout AppSettings) -> Void) async throws {}
}

private final class NoopNotificationService: NotificationService {
    func requestAuthorization() async throws -> Bool { false }
    func notify(title: String, subtitle: String, attachmentURL: URL?, identifierSuffix: String?) async throws {}
}

private struct NoopAlbumArtCache: AlbumArtCache {
    func image(for coverPath: String) async -> NSImage? { nil }
}

private struct NoopPlayerEngine: PlayerEngine {
    let error: Error
    var events: AsyncStream<PlayerEvent> { AsyncStream { $0.finish() } }
    func play(url: URL, startSeconds: Double?) async throws { throw error }
    func pause() async throws { throw error }
    func resume() async throws { throw error }
    func stop() async throws { throw error }
    func seek(to seconds: Double) async throws { throw error }
    func setOutputDevice(uid: String?) async throws { throw error }
    func shutdown() async {}
}

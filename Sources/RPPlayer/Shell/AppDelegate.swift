import AppKit
import Foundation
import SwiftUI
import UserNotifications

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    struct Bootstrap {
        let viewModel: MiniPlayerViewModel
        let notificationCoordinator: NotificationCoordinator
        let coordinatorShutdown: @Sendable () async -> Void
    }

    private(set) var statusItemController: StatusItemController?
    private(set) var viewModel: MiniPlayerViewModel?
    private(set) var notificationCoordinator: NotificationCoordinator?
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
        self.coordinatorShutdown = result.coordinatorShutdown

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
        let logger = AppLogger(category: "shell")
        let configURL = ConfigPaths.configFile
        let initial = Self.loadSettings(from: configURL)
        let store: JSONConfigStore?
        do {
            store = try JSONConfigStore(url: configURL)
        } catch {
            logger.error("Failed to open config store: \(error.localizedDescription)")
            store = nil
        }

        let cookieProvider = AnonymousCookieProvider()
        let api = LiveRpApiClient(cookieProvider: cookieProvider, logger: logger)

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
            bitrate: initial.bitrate
        )

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

        let viewModel = MiniPlayerViewModel(
            coordinator: coordinator,
            api: api,
            initialChannelId: initial.selectedChannelId,
            albumArtCache: cache,
            auth: KeychainCookieProvider(),
            openSettings: { },
            persistChannelId: { id in
                guard let store else { return }
                try? await store.update { $0.selectedChannelId = id }
            }
        )

        Task {
            // Best-effort authorization request; fails silently in unbundled processes.
            _ = try? await notificationService.requestAuthorization()
        }

        return Bootstrap(
            viewModel: viewModel,
            notificationCoordinator: notificationCoordinator,
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

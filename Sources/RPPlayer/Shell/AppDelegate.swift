import AppKit
import Foundation
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    struct Bootstrap {
        let viewModel: MiniPlayerViewModel
        let coordinatorShutdown: () async -> Void
    }

    private(set) var statusItemController: StatusItemController?
    private(set) var viewModel: MiniPlayerViewModel?
    private var coordinatorShutdown: (() async -> Void)?
    private let bootstrap: () -> Bootstrap

    convenience override init() {
        self.init(bootstrap: AppDelegate.realBootstrap)
    }

    init(bootstrap: @escaping () -> Bootstrap) {
        self.bootstrap = bootstrap
        super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // initialChannelId comes from ConfigStore in the real bootstrap; tests can pass whatever they like through the override.
        let result = bootstrap()
        self.viewModel = result.viewModel
        self.coordinatorShutdown = result.coordinatorShutdown

        let popover = PopoverController(rootView: AnyView(MiniPlayerView(viewModel: result.viewModel)))
        statusItemController = StatusItemController(popover: popover)
    }

    func applicationWillTerminate(_ notification: Notification) {
        guard let shutdown = coordinatorShutdown else { return }
        // Block the terminate path on a clean shutdown of the coordinator —
        // libmpv must release the audio device before we exit.
        let group = DispatchGroup()
        group.enter()
        Task { @MainActor in
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

        let viewModel = MiniPlayerViewModel(
            coordinator: coordinator,
            api: api,
            initialChannelId: initial.selectedChannelId,
            persistChannelId: { id in
                guard let store else { return }
                try? await store.update { $0.selectedChannelId = id }
            }
        )

        return Bootstrap(
            viewModel: viewModel,
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

private struct NoopPlayerEngine: PlayerEngine {
    let error: Error
    var events: AsyncStream<PlayerEvent> { AsyncStream { _ in } }
    func play(url: URL) async throws { throw error }
    func pause() async throws { throw error }
    func resume() async throws { throw error }
    func stop() async throws { throw error }
    func seek(to seconds: Double) async throws { throw error }
    func setHogMode(_ enabled: Bool) async throws { throw error }
    func setOutputDevice(uid: String?) async throws { throw error }
    func shutdown() async {}
}

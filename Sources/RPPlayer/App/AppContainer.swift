import AppKit
import Foundation
import Security
import SwiftUI
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
    let pastSongPopoverController: PopoverController
    let upcomingWindowController: UpcomingWindowController
    let configStore: any ConfigStore
    let nowPlayingCenterController: NowPlayingCenterController
    let updateChecker: any UpdateChecking
    let initialMenuBarIconStyle: MenuBarIconStyle

    let quietNow: @Sendable () -> Void

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
        pastSongPopoverController: PopoverController,
        upcomingWindowController: UpcomingWindowController,
        configStore: any ConfigStore,
        nowPlayingCenterController: NowPlayingCenterController,
        updateChecker: any UpdateChecking = NoopUpdateChecker(),
        initialMenuBarIconStyle: MenuBarIconStyle = .template,
        coordinatorShutdown: @escaping @Sendable () async -> Void,
        quietNow: @escaping @Sendable () -> Void = {},
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
        self.configStore = configStore
        self.nowPlayingCenterController = nowPlayingCenterController
        self.updateChecker = updateChecker
        self.initialMenuBarIconStyle = initialMenuBarIconStyle
        self.coordinatorShutdown = coordinatorShutdown
        self.quietNow = quietNow
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

@MainActor
final class DeviceReattachState {
    var heldUID: String?
    var reattachTask: Task<Void, Never>?
    var lastKnownDeviceNames: [String: String] = [:]
    // Late-bound by AppContainer.live() once MiniPlayerViewModel exists.
    var onReattached: @MainActor () -> Void = { }

    func cancelReattach() {
        reattachTask?.cancel()
        reattachTask = nil
        heldUID = nil
    }
}

extension AppContainer {
    static func live() throws -> AppContainer {
        let logger = AppLogger.fileBacked(category: "shell", directory: ConfigPaths.logsDirectory)
        let eqLogger = AppLogger.fileBacked(category: "eq", directory: ConfigPaths.logsDirectory)
        logger.info("AppContainer.live() starting")
        let configURL = ConfigPaths.configFile
        let loaded = Self.loadSettings(from: configURL)
        logger.setVerbose(loaded.verboseLoggingEnabled)
        eqLogger.setVerbose(loaded.verboseLoggingEnabled)
        logger.info("loaded settings: hog=\(loaded.hogModeEnabled) device=\(loaded.outputDeviceUID ?? "nil") bitrate=\(loaded.bitrate) verboseLogging=\(loaded.verboseLoggingEnabled)")
        let store: JSONConfigStore?
        do {
            store = try JSONConfigStore(url: configURL)
        } catch {
            logger.error("Failed to open config store: \(error.localizedDescription)")
            store = nil
        }

        // Hearing-safety on startup: if the saved output device isn't present
        // (e.g. user quit with DAC connected, then unplugged it before the next
        // launch), clear hog mode + force-max + the stale device UID. Without
        // this, the next channel switch can fall back to built-in speakers and
        // pin them at 100% — matching what the runtime -14 path does, but
        // proactively so the user doesn't even need to click play first.
        let initial: AppSettings = {
            guard let uid = loaded.outputDeviceUID, !uid.isEmpty else { return loaded }
            let knownUIDs = Set(CoreAudioDeviceLister().currentDevices().map { $0.uid })
            if knownUIDs.contains(uid) { return loaded }
            logger.info("saved output device '\(uid)' not present at startup; clearing hog + volumeMode + outputDeviceUID for safety")
            if let store {
                Task { try? await store.update {
                    $0.hogModeEnabled = false
                    $0.volumeMode = .none
                    $0.outputDeviceUID = nil
                } }
            }
            var safe = loaded
            safe.hogModeEnabled = false
            safe.volumeMode = .none
            safe.outputDeviceUID = nil
            return safe
        }()
        let startupProfile = initial.outputDeviceUID.flatMap { initial.audioProfiles[$0] } ?? AudioProfile.safeDefault

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

        let eqPresetStore: any EqPresetStore = LiveEqPresetStore(directory: ConfigPaths.eqPresetsDirectory, logger: eqLogger)

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

        let songFileCache: any SongFileCache
        do {
            songFileCache = try LiveSongFileCache(
                directory: ConfigPaths.songFileCacheDirectory,
                logger: logger
            )
        } catch {
            logger.error("Failed to open song file cache: \(error.localizedDescription)")
            songFileCache = NoopSongFileCache()
        }

        let engine: any PlayerEngine
        do {
            // Force-max forces replaygain out of the signal path regardless of the
            // user's stored replaygain intent (which is preserved for restore).
            let effectiveReplayGain = startupProfile.volumeMode == .replayGain
            engine = try MpvPlayerEngine(
                initialDeviceUID: initial.outputDeviceUID,
                initialForceMaxVolume: startupProfile.volumeMode == .forceMax,
                initialApplyReplayGain: effectiveReplayGain,
                logger: logger
            )
        } catch {
            // Keep the menu-bar shell up so the user can see the error banner
            // even when libmpv fails to initialise (missing dylib, audio-device
            // contention, etc.).
            engine = NoopPlayerEngine(error: error)
        }

        let hogController = HogModeController()
        let volumeController = DeviceVolumeController()
        // Skip the launch-time acquire when release-on-pause is on: nothing is
        // playing yet, so grabbing the device would block other apps for no
        // benefit. The state-stream subscriber below acquires on first .playing.
        if startupProfile.hogModeEnabled, !startupProfile.releaseHogOnPauseEnabled,
           let uid = initial.outputDeviceUID, !uid.isEmpty {
            Task { _ = await hogController.acquire(deviceUID: uid) }
        }
        if startupProfile.volumeMode == .forceMax, let uid = initial.outputDeviceUID, !uid.isEmpty {
            Task { _ = await volumeController.setVolumeMax(deviceUID: uid) }
        }

        let coordinator = LivePlaybackCoordinator(
            api: api,
            engine: engine,
            songFileCache: songFileCache,
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
            },
            onDeviceUnavailable: { [store, hogController, logger] in
                // Hearing-safety reset when mpv reports MPV_ERROR_AO_INIT_FAILED:
                // drop hog mode + force-max + the dead UID so the next device the
                // user picks (often built-in speakers) doesn't blast at 100% and
                // the Settings UI doesn't keep showing a device that's no longer
                // present. Release hog explicitly too so we're not still holding
                // the (now-gone) device.
                guard let store else { return }
                logger.info("device unavailable: clearing hogModeEnabled + volumeMode + outputDeviceUID for safety")
                try? await store.update {
                    $0.hogModeEnabled = false
                    $0.volumeMode = .none
                    $0.outputDeviceUID = nil
                }
                await hogController.release()
            },
            prePlayHook: { [store, hogController] in
                // Acquire hog BEFORE mpv opens the CoreAudio AO. Without this,
                // mpv's shared-mode AO open can race with hog acquisition (which
                // currently fires on the .playing state transition, after engine.play
                // returns) and end up registered but silent until the user toggles
                // pause+play to force an AO recreate. Especially visible when another
                // app (e.g. a YouTube tab) was already feeding the device.
                guard let store else { return }
                let s = await store.settings
                guard s.hogModeEnabled, let uid = s.outputDeviceUID, !uid.isEmpty else { return }
                _ = await hogController.acquire(deviceUID: uid)
            }
        )

        // Bridge persistent audio settings → engine. The stream yields the
        // current snapshot first, so initial hog-mode + device UID get applied
        // before the user ever opens the popover. Subsequent settings changes
        // propagate on every save. mpv applies these on next file-load, so
        // toggling mid-playback requires a stop/play to take effect.
        if let store {
            Task { [engine, hogController, volumeController, coordinator, store] in
                let stream = await store.changes
                var lastForceMax = startupProfile.volumeMode == .forceMax
                var lastEffectiveRG = startupProfile.volumeMode == .replayGain
                var lastDeviceUID = initial.outputDeviceUID
                var lastHog = startupProfile.hogModeEnabled
                var lastBitrate = initial.bitrate
                for await settings in stream {
                    // Device switch: load the saved profile for the new device (or safe
                    // defaults) and atomically overwrite the top-level fields before any
                    // controller write so no stale setting ever reaches the new device.
                    if settings.outputDeviceUID != lastDeviceUID {
                        let newUID = settings.outputDeviceUID
                        let profile = newUID.flatMap { settings.audioProfiles[$0] } ?? AudioProfile.safeDefault
                        try? await store.update { s in
                            s.hogModeEnabled = profile.hogModeEnabled
                            s.releaseHogOnPauseEnabled = profile.releaseHogOnPauseEnabled
                            s.volumeMode = profile.volumeMode
                            s.bitrate = profile.bitrate
                            if let uid = newUID, s.audioProfiles[uid] == nil {
                                s.audioProfiles[uid] = profile
                            }
                        }
                        if profile.bitrate != settings.bitrate,
                           await coordinator.currentPlaybackState == .playing,
                           let channelId = await coordinator.nowPlaying?.channelId {
                            try? await coordinator.changeChannel(to: channelId)
                        }
                        // Force force-max re-evaluation on the next iteration so that
                        // switching between two devices that both have force-max ON still
                        // pins the volume on the new device.
                        lastForceMax = profile.volumeMode != .forceMax
                        lastDeviceUID = newUID
                        lastBitrate = profile.bitrate
                        continue
                    }
                    // Bare bitrate change (no device switch): swap the queued-next
                    // entry to the new bitrate immediately instead of waiting for
                    // the 20-song queue to drain.
                    if settings.bitrate != lastBitrate {
                        lastBitrate = settings.bitrate
                        if await coordinator.nowPlaying != nil {
                            await coordinator.applyBitrateChange()
                        }
                    }
                    // Hog acquire reflects current playback state: when release-on-pause
                    // is on AND we're paused/stopped, don't grab the device just because
                    // the user toggled hog ON. The state-stream subscriber below covers
                    // re-acquisition on resume.
                    let state = await coordinator.currentPlaybackState
                    let wantHog = settings.hogModeEnabled
                        && (!settings.releaseHogOnPauseEnabled || state == .playing)
                    if wantHog, let uid = settings.outputDeviceUID, !uid.isEmpty {
                        _ = await hogController.acquire(deviceUID: uid)
                    } else {
                        await hogController.release()
                    }
                    try? await engine.setOutputDevice(uid: settings.outputDeviceUID)
                    let deviceChanged = settings.outputDeviceUID != lastDeviceUID
                    lastDeviceUID = settings.outputDeviceUID

                    // Hog OFF → ON transition: if forceMax is set but the device is not
                    // at max, demote to .none. This prevents locking a non-max volume.
                    // Does NOT promote .none → .forceMax when the device happens to be at max.
                    let hogTurnedOn = settings.hogModeEnabled && !lastHog
                    let hogTurnedOff = !settings.hogModeEnabled && lastHog
                    lastHog = settings.hogModeEnabled
                    if hogTurnedOn, let uid = settings.outputDeviceUID, !uid.isEmpty {
                        let v = await volumeController.currentVolume(deviceUID: uid)
                        let isMax = (v ?? 0) >= 0.999
                        let isForceMax = settings.volumeMode == .forceMax
                        if isForceMax && !isMax {
                            try? await store.update { $0.volumeMode = .none }
                            // Settings stream will re-emit; let the next iteration
                            // handle engine.setForceMaxVolume + locking.
                            continue
                        }
                    }
                    // Hog ON → OFF transition: if forceMax is set, demote to .none. Without
                    // hog the OS slider can override the device pin, so the UI's force-max
                    // button is disabled in this state — keeping volumeMode at .forceMax
                    // would leave a "filled but disabled" button stuck in a meaningless state.
                    if hogTurnedOff, settings.volumeMode == .forceMax {
                        try? await store.update { $0.volumeMode = .none }
                        continue
                    }
                    let nowForceMax = settings.volumeMode == .forceMax
                    if nowForceMax != lastForceMax {
                        try? await engine.setForceMaxVolume(nowForceMax)
                        lastForceMax = nowForceMax
                        if nowForceMax, let uid = settings.outputDeviceUID, !uid.isEmpty {
                            _ = await volumeController.setVolumeMax(deviceUID: uid)
                        }
                    } else if nowForceMax, deviceChanged,
                              let uid = settings.outputDeviceUID, !uid.isEmpty {
                        // Device switched while force-max stayed on — reapply to the new device.
                        _ = await volumeController.setVolumeMax(deviceUID: uid)
                    }
                    let effectiveRG = settings.volumeMode == .replayGain
                    if effectiveRG != lastEffectiveRG {
                        try? await engine.setApplyReplayGain(effectiveRG)
                        lastEffectiveRG = effectiveRG
                    }
                    if let uid = settings.outputDeviceUID {
                        try? await store.update { s in
                            let existing = s.audioProfiles[uid] ?? AudioProfile.safeDefault
                            s.audioProfiles[uid] = AudioProfile(
                                hogModeEnabled: s.hogModeEnabled,
                                releaseHogOnPauseEnabled: s.releaseHogOnPauseEnabled,
                                volumeMode: s.volumeMode,
                                bitrate: s.bitrate,
                                eqEnabled: existing.eqEnabled,
                                eqPresetName: existing.eqPresetName,
                                crossfeedEnabled: existing.crossfeedEnabled,
                                crossfeedStrength: existing.crossfeedStrength,
                                crossfeedRange: existing.crossfeedRange
                            )
                        }
                    }
                }
            }
            // Release/re-acquire hog on pause/resume when the user opted in.
            // Also pin device volume to max on every .playing transition when
            // force-max is on, in case the user nudged the OS slider while paused.
            Task { [hogController, volumeController, coordinator, store] in
                let stream = await coordinator.stateUpdates
                for await state in stream {
                    let s = await store.settings
                    guard let uid = s.outputDeviceUID, !uid.isEmpty else { continue }
                    if s.hogModeEnabled, s.releaseHogOnPauseEnabled {
                        switch state {
                        case .playing:
                            _ = await hogController.acquire(deviceUID: uid)
                        case .paused, .stopped:
                            await hogController.release()
                        case .loading:
                            break
                        }
                    }
                    if state == .playing, s.volumeMode == .forceMax {
                        _ = await volumeController.setVolumeMax(deviceUID: uid)
                    }
                }
            }
            Task { [logger, eqLogger] in
                let stream = await store.changes
                for await settings in stream {
                    logger.setVerbose(settings.verboseLoggingEnabled)
                    eqLogger.setVerbose(settings.verboseLoggingEnabled)
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
            Task { [engine, eqPresetStore, store] in
                await AppContainer.runAudioFilterBinder(
                    store: store,
                    engine: engine,
                    eqPresetStore: eqPresetStore,
                    initialProfile: startupProfile
                )
            }
        }

        let deviceCatalog = CoreAudioDeviceCatalog(lister: CoreAudioDeviceLister())
        // Observe CoreAudio hot-plug events so the Settings device list stays
        // current AND so we can clear the saved UID when the user's selected
        // device disappears at runtime (e.g. USB DAC unplug). Without this, the
        // UI keeps showing the now-gone device and a replug doesn't restore it
        // until the user manually switches channels.
        Task { await deviceCatalog.startWatching() }
        if let store {
            Task { [logger] in
                let stream = await deviceCatalog.changes
                for await devices in stream {
                    let s = await store.settings
                    guard let uid = s.outputDeviceUID, !uid.isEmpty else { continue }
                    if devices.contains(where: { $0.uid == uid }) { continue }
                    logger.info("output device '\(uid)' disappeared at runtime; clearing hogModeEnabled + volumeMode + outputDeviceUID for safety")
                    try? await store.update {
                        $0.hogModeEnabled = false
                        $0.volumeMode = .none
                        $0.outputDeviceUID = nil
                    }
                }
            }
        }

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

        let updateChecker: any UpdateChecking
        if let raw = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String,
           let version = SemVer.parse(raw) {
            updateChecker = UpdateChecker(
                currentVersion: version,
                repoOwner: "gvajda",
                repoName: "rp-player",
                urlSession: .shared,
                configStore: store ?? NoopConfigStore(),
                logger: logger,
                clock: { Date() }
            )
            logger.info("update checker: live (currentVersion=\(version.major).\(version.minor).\(version.patch))")
        } else {
            updateChecker = NoopUpdateChecker()
            logger.info("update checker: noop (no CFBundleShortVersionString)")
        }

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
            listChannels: { [api] in try await api.listChannels() },
            updateChecker: updateChecker,
            eqPresetStore: eqPresetStore,
            logger: eqLogger
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
            },
            updateChecker: updateChecker
        )

        let upcomingViewModel = UpcomingProgramViewModel(
            api: api,
            albumArtCache: cache,
            configStore: store ?? NoopConfigStore(),
            paletteExtractor: AmbientPaletteExtractor(),
            coordinator: coordinator,
            selectChannelHandler: { [viewModel] id in await viewModel.selectChannel(id) }
        )
        let upcomingWindowController = UpcomingWindowController(viewModel: upcomingViewModel, configStore: store ?? NoopConfigStore())
        viewModel.upcomingAction = { [upcomingWindowController] in
            Task { @MainActor in await upcomingWindowController.show() }
        }

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
            },
            { [updateChecker] in
                await updateChecker.start()
            }
        ]

        let nowPlayingCenterController = NowPlayingCenterController(
            coordinator: coordinator,
            albumArtCache: cache
        )

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
            pastSongPopoverController: PopoverController(rootView: AnyView(EmptyView()), configStore: store ?? NoopConfigStore()),
            upcomingWindowController: upcomingWindowController,
            configStore: store ?? NoopConfigStore(),
            nowPlayingCenterController: nowPlayingCenterController,
            updateChecker: updateChecker,
            initialMenuBarIconStyle: initial.menuBarIconStyle,
            coordinatorShutdown: { await coordinator.shutdown(); await hogController.release() },
            quietNow: { engine.muteImmediately() },
            onLaunchTasks: onLaunchTasks
        )
    }

    internal static func runAudioFilterBinder(
        store: any ConfigStore,
        engine: any PlayerEngine,
        eqPresetStore: any EqPresetStore,
        initialProfile: AudioProfile
    ) async {
        var last = AudioFilterKey(profile: initialProfile)
        await applyAudioFilterState(engine: engine, store: eqPresetStore, key: last)

        for await snapshot in await store.changes {
            let uid = snapshot.outputDeviceUID
            let profile = uid.flatMap { snapshot.audioProfiles[$0] } ?? AudioProfile.safeDefault
            let next = AudioFilterKey(profile: profile)
            if next != last {
                last = next
                await applyAudioFilterState(engine: engine, store: eqPresetStore, key: next)
            }
        }
    }

    internal static func applyAudioFilterState(
        engine: any PlayerEngine,
        store: any EqPresetStore,
        key: AudioFilterKey
    ) async {
        var parts: [String] = []
        if key.eqEnabled, let name = key.eqPresetName {
            do {
                let raw = try await store.loadText(name: name)
                if case .success(let preset) = EqPresetParser.parse(text: raw, filename: name) {
                    parts = EqChainBuilder.buildParts(preset)
                }
            } catch {
                // File missing or unreadable → EQ contributes nothing. Crossfeed may still apply below.
            }
        }
        if key.crossfeedEnabled {
            parts.append(CrossfeedFilterBuilder.buildPart(
                strength: key.crossfeedStrength,
                range: key.crossfeedRange
            ))
        }
        if parts.isEmpty {
            try? await engine.setAudioFilterChain(nil)
        } else {
            try? await engine.setAudioFilterChain("lavfi=[" + parts.joined(separator: ",") + "]")
        }
    }

    internal struct AudioFilterKey: Equatable {
        let eqEnabled: Bool
        let eqPresetName: String?
        let crossfeedEnabled: Bool
        let crossfeedStrength: Double
        let crossfeedRange: Double

        init(profile: AudioProfile) {
            self.eqEnabled = profile.eqEnabled
            self.eqPresetName = profile.eqPresetName
            self.crossfeedEnabled = profile.crossfeedEnabled
            self.crossfeedStrength = profile.crossfeedStrength
            self.crossfeedRange = profile.crossfeedRange
        }
    }

    @discardableResult
    static func handleDeviceLost(
        store: JSONConfigStore,
        hogController: HogModeController,
        knownDeviceNames: [String: String],
        logger: any Logging
    ) async -> (message: String?, preservedUID: String?) {
        let s = await store.settings
        guard let uid = s.outputDeviceUID, !uid.isEmpty else {
            return (nil, nil)
        }
        if s.hogModeEnabled {
            let name = knownDeviceNames[uid] ?? uid
            logger.info("device '\(uid)' disappeared while hog mode on; preserving selection + waiting for reattach")
            // release() clears the actor's bookkeeping unconditionally even when the
            // CoreAudio call against the dead device fails.
            await hogController.release()
            return ("\(name) disconnected — waiting for it to come back.", uid)
        } else {
            logger.info("output device '\(uid)' disappeared at runtime; clearing hogModeEnabled + volumeMode + outputDeviceUID for safety")
            try? await store.update {
                $0.hogModeEnabled = false
                $0.volumeMode = .none
                $0.outputDeviceUID = nil
            }
            await hogController.release()
            return (
                "Audio device unavailable. Hog mode + Force Max Volume turned off so the next device you pick can't surprise you. Check System Settings → Sound → Output.",
                nil
            )
        }
    }

    static func spawnReattachWatcher(
        heldUID: String,
        catalog: CoreAudioDeviceCatalog,
        hogController: HogModeController,
        volumeController: DeviceVolumeController,
        store: JSONConfigStore,
        logger: any Logging,
        onReattached: @escaping @MainActor () -> Void
    ) -> Task<Void, Never> {
        Task { [catalog, hogController, volumeController, store, logger] in
            let stream = await catalog.changes
            for await devices in stream {
                if Task.isCancelled { return }
                guard devices.contains(where: { $0.uid == heldUID }) else { continue }
                logger.info("held device '\(heldUID)' reappeared; re-acquiring hog")
                _ = await hogController.acquire(deviceUID: heldUID)
                let s = await store.settings
                if s.volumeMode == .forceMax {
                    _ = await volumeController.setVolumeMax(deviceUID: heldUID)
                }
                await MainActor.run { onReattached() }
                return
            }
        }
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

// Falls back to the remote URL so playback still works if the cache dir can't be created.
private actor NoopSongFileCache: SongFileCache {
    func localFile(for song: GaplessSong) async -> URL? { URL(string: song.gaplessUrl) }
    nonisolated func cachedFile(for song: GaplessSong) -> URL? { nil }
    func evict(_ song: GaplessSong) async {}
    func clear() async {}
    func cancelInFlightDownloads() async {}
    nonisolated func expectedLocalPath(for song: GaplessSong) -> URL {
        URL(string: song.gaplessUrl) ?? URL(fileURLWithPath: "/dev/null")
    }
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
    func setForceMaxVolume(_ enabled: Bool) async throws { throw error }
    func setApplyReplayGain(_ enabled: Bool) async throws { throw error }
    func setAudioFilterChain(_ chain: String?) async throws { throw error }
    func setMute(_ muted: Bool) async throws { throw error }
    func queueNext(url: URL, startSeconds: Double?) async throws { throw error }
    func advanceToQueued() async throws { throw error }
    func clearPlaylist() async throws { throw error }
    func currentPath() async -> String? { nil }
    func shutdown() async {}
}

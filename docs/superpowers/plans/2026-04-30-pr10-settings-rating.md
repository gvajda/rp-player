# PR 10 — SettingsView + Rating Row Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Ship a `SettingsView` (audio device picker, hog/software-volume/notifications toggles, bitrate picker, account section with login/logout, "Show Data Folder" + "Show Logs" buttons) hosted in a dedicated `NSWindow` opened from a gear button in `MiniPlayerView`. Add a 1–10 rating row to `MiniPlayerView` that reads `userRating` from the current song and POSTs via `RpApiClient.rate(...)` when the user is signed in. Wire `KeychainCookieProvider` into `realBootstrap` (replacing `AnonymousCookieProvider`) so authenticated requests carry the cookie.

**Architecture:**
- `SettingsViewModel` (`@MainActor final class: ObservableObject`) bridges `ConfigStore.changes`, `AudioDeviceCatalog.changes`, and a small auth-state surface to `@Published` state. Methods mutate `ConfigStore` for persistent settings and call `KeychainAuth.clearCookie()` for sign-out.
- `SettingsView` (SwiftUI Form with Sections) renders the model and dispatches user actions. Account section uses an injected closure to open the existing `LoginWindowController` (PR 3) on "Sign in".
- `SettingsWindowController` (`@MainActor final class: NSWindowController`) hosts `SettingsView` in a non-resizable 480×560 window with `.titled, .closable` style.
- `MiniPlayerView` gains a small toolbar row at the top: a gear button (opens settings) and the existing channel picker + skip/play. The rating row sits below the metadata.
- `RatingRow` is a 10-button `HStack` rendered inside `MiniPlayerView`. Disabled if `viewModel.isSignedIn == false`. Shows the current rating from `nowPlaying.song.userRating` (or last-known via the view model's local cache).
- `MiniPlayerViewModel` gains `isSignedIn: Bool`, `currentRating: Int?`, and a `rate(_ value: Int)` method that calls `RpApiClient.rate(songId:rating:)` and updates local state on success.
- `AppDelegate.realBootstrap` swaps `AnonymousCookieProvider` for `KeychainCookieProvider` (backed by the existing `KeychainStore`), constructs a single `LoginWindowController` (or builds it on demand), retains a `SettingsWindowController`, and exposes `KeychainAuth` to both view models.

**Tech Stack:** Swift 6.2, SwiftUI (`Form`, `Section`, `Picker`, `Toggle`), AppKit (`NSWindow`, `NSWindowController`, `NSWorkspace.shared.open`), XCTest.

---

## File structure

**Created**

- `Sources/RPPlayer/Shell/SettingsViewModel.swift` — `@MainActor final class: ObservableObject` reading `ConfigStore.settings`, `AudioDeviceCatalog.devices`, and `KeychainAuth.isLoggedIn`.
- `Sources/RPPlayer/Shell/SettingsView.swift` — SwiftUI `Form` with sections: Audio (device picker w/ bus-type label, hog mode toggle, software volume toggle, bitrate picker), Notifications (single toggle), Account (status row + Sign in/out button), Data (Show data folder, Show logs).
- `Sources/RPPlayer/Shell/SettingsWindowController.swift` — `@MainActor final class: NSWindowController` hosting `NSHostingView<SettingsView>`.
- `Sources/RPPlayer/Shell/RatingRow.swift` — small SwiftUI struct rendering 10 buttons + a disabled state.
- `Tests/RPPlayerTests/Shell/SettingsViewModelTests.swift`
- `Tests/RPPlayerTests/Shell/SettingsViewTests.swift`
- `Tests/RPPlayerTests/Shell/SettingsWindowControllerTests.swift`
- `Tests/RPPlayerTests/Shell/RatingRowTests.swift`

**Modified**

- `Sources/RPPlayer/Shell/MiniPlayerView.swift` — add gear button at the top (opens settings via injected closure), insert `RatingRow` below metadata.
- `Sources/RPPlayer/Shell/MiniPlayerViewModel.swift` — add `isSignedIn: Bool`, `currentRating: Int?`, `rate(_:)`, and accept an `auth: any KeychainAuth` plus an `openSettings: @MainActor () -> Void` closure at init. Refresh `isSignedIn` on every `nowPlaying` update so the rating row enables itself when the user signs in mid-session.
- `Sources/RPPlayer/Shell/AppDelegate.swift` — `realBootstrap` builds `KeychainStore` → `KeychainCookieProvider` → `LoginWindowController` → `SettingsWindowController` → `SettingsViewModel`. Swap `AnonymousCookieProvider` for `KeychainCookieProvider`. Pass `auth` and `openSettings` into `MiniPlayerViewModel`. Add `loginWindowController` and `settingsWindowController` to `Bootstrap` so they outlive `applicationDidFinishLaunching`.
- `Sources/RPPlayer/Shell/MiniPlayerViewModel.swift` — also incorporate the PR 9 review I2 follow-up: clear `currentArt = nil` immediately when `nowPlaying` flips so the user never sees old-art-with-new-title.
- `Sources/RPPlayer/Shell/PopoverController.swift` — gate the local Esc-key monitor on `event.window === panel` so Esc inside the new settings window doesn't dismiss the popover (PR 7 review I2 + PR 9 review carry-over).
- `Tests/RPPlayerTests/Shell/MiniPlayerViewModelTests.swift` — add tests for sign-in tracking, `rate(_:)` success/failure, and the `currentArt` clear-on-flip behavior.
- `Tests/RPPlayerTests/Shell/AppDelegateTests.swift` — extend the bootstrap injection with stub `KeychainAuth`, login/settings window controllers (or skip retaining them in tests).
- `CLAUDE.md` — flip PR 10 to ✅, mark PR 11 as next, append the new test count, record PR-10-specific decisions.

**Untouched**

- All PR 1–9 modules outside the explicit list above.

---

## Conventions used by this PR

- **Account section is settings-side, not popover-side.** DESIGN.md §4 lists Account in `SettingsView`. The popover only surfaces the rating row; "sign in to rate" UX is a disabled-state hint plus a 1-line tooltip pointing the user at Settings.
- **Settings window is created once at launch and re-shown on every "open" call.** `NSWindowController` reuses the same `NSWindow` across show/hide cycles. Closing the window orderOuts it; showing again `makeKeyAndOrderFront`s.
- **Bus-type labels follow PR 4's `TransportType.label`.** No new transport-type strings introduced.
- **Bitrate values are the API's literal codes** (0..4). The picker renders human strings ("AAC 64 kbps", "FLAC (highest)") but stores `Int`.
- **Auth state surface:** `MiniPlayerViewModel.isSignedIn` reads `keychainAuth.isLoggedIn` (the existing protocol method on `KeychainAuth` from PR 3). No streaming — re-checked on every `nowPlaying` update and after the login window closes. Tests substitute a stub.
- **Login flow:** `LoginWindowController` writes the cookie blob to keychain on success, then `close()`s. PR 10 does NOT add a "logged in" event stream; instead, the next API call picks up the cookie via `KeychainCookieProvider.currentCookie()` and the view model refreshes `isSignedIn` on the next `nowPlaying` emission. Tests assert the closure path.
- **Rating writes are best-effort.** RP API quietly succeeds for anonymous users (no server-side change). PR 10 still gates the rating row's interactivity on `isSignedIn` so anonymous users don't waste a network call.
- **Strict comment policy.** No comments unless WHY non-obvious; single-line `//` only.

### Verified upstream symbols (do NOT regress)

- `AudioDeviceCatalog` protocol: `var devices: [AudioDevice] { get async }`, `var changes: AsyncStream<[AudioDevice]> { get async }`. Concrete impl: `CoreAudioDeviceCatalog`.
- `AudioDevice` struct fields: `uid: String`, `name: String`, `transportType: TransportType`. The "bit-perfect recommended" hint lives on `TransportType.isBitPerfectRecommended` (the enum), NOT the device.
- `TransportType` is an enum with cases `.builtIn`, `.usb`, `.thunderbolt`, `.hdmi`, `.bluetooth`, `.airplay`, `.unknown`. It does NOT currently expose a UI-friendly `label: String` — Task 2 adds one (small extension).
- `KeychainStore` protocol: `load() throws -> String?`, `save(_ blob: String) throws`, `delete() throws`. Concrete impl is `SecItemKeychainStore` (not `LiveKeychainStore`).
- `CoreAudioDeviceCatalog` is the concrete `AudioDeviceCatalog` (not `LiveAudioDeviceCatalog`).
- `KeychainAuth` protocol: `var isLoggedIn: Bool { get }`, `func storeCookie(_:) async throws`, `func clearCookie() async throws`.
- `KeychainCookieProvider: CookieProvider, KeychainAuth` — single concrete impl already wired into PR 3. `init(keychainStore:)`.
- `LoginWindowController.init(keychainAuth: any KeychainAuth)`, `show()`. The window writes the cookie + closes itself on successful login.
- `RpApiClient.rate(songId: Int, rating: Int) async throws -> Rating`. The view model passes `Int(nowPlaying.song.songId) ?? 0`.
- `ConfigStore.update { mutator }` already async-isolated. `JSONConfigStore.changes` async-yields settings.
- `ConfigPaths.applicationSupportRoot: URL`, `ConfigPaths.logsDirectory: URL`. Used by the "Show data folder" / "Show logs" buttons via `NSWorkspace.shared.open(_:)`.

---

## Task 1: `SettingsViewModel`

**Files:**
- Create: `Sources/RPPlayer/Shell/SettingsViewModel.swift`
- Create: `Tests/RPPlayerTests/Shell/SettingsViewModelTests.swift`

The view model owns `@Published` state and forwards mutations to `ConfigStore`. It does NOT own the device-list subscription `Task` from `init` — call `start()` from the view's `.task` modifier (mirrors `MiniPlayerViewModel`).

- [ ] **Step 1: Write failing initial-state test**

`Tests/RPPlayerTests/Shell/SettingsViewModelTests.swift`:

```swift
import XCTest
@testable import RPPlayer

@MainActor
final class SettingsViewModelTests: XCTestCase {
    private var configStore: StubConfigStore!
    private var deviceCatalog: StubAudioDeviceCatalog!
    private var auth: StubKeychainAuth!
    private var sut: SettingsViewModel!

    override func setUp() async throws {
        configStore = StubConfigStore(initial: AppSettings.default)
        deviceCatalog = StubAudioDeviceCatalog(initial: [])
        auth = StubKeychainAuth()
        sut = SettingsViewModel(
            configStore: configStore,
            deviceCatalog: deviceCatalog,
            auth: auth,
            openLoginWindow: { },
            openDataFolder: { },
            openLogsFolder: { }
        )
    }

    override func tearDown() async throws {
        await sut.stop()
    }

    func testInitialStateMirrorsAppSettingsDefault() {
        XCTAssertEqual(sut.selectedChannelId, AppSettings.default.selectedChannelId)
        XCTAssertEqual(sut.bitrate, AppSettings.default.bitrate)
        XCTAssertEqual(sut.hogModeEnabled, AppSettings.default.hogModeEnabled)
        XCTAssertEqual(sut.softwareVolumeEnabled, AppSettings.default.softwareVolumeEnabled)
        XCTAssertEqual(sut.notificationsEnabled, AppSettings.default.notificationsEnabled)
        XCTAssertEqual(sut.outputDeviceUID, AppSettings.default.outputDeviceUID)
        XCTAssertTrue(sut.devices.isEmpty)
        XCTAssertFalse(sut.isSignedIn)
    }
}
```

- [ ] **Step 2: Run, expect compile failure**

Run: `swift test --filter RPPlayerTests.SettingsViewModelTests`
Expected: `SettingsViewModel` undefined plus stubs undefined.

- [ ] **Step 3: Add the stubs**

Place these in `Tests/RPPlayerTests/Shell/SettingsViewModelTests.swift` (or hoist later if reused):

```swift
@MainActor
final class StubConfigStore: ConfigStore {
    var current: AppSettings
    var continuations: [AsyncStream<AppSettings>.Continuation] = []

    init(initial: AppSettings) { self.current = initial }

    var settings: AppSettings { get async { current } }

    var changes: AsyncStream<AppSettings> {
        AsyncStream { continuation in
            continuation.yield(current)
            continuations.append(continuation)
        }
    }

    func update(_ mutate: @Sendable (inout AppSettings) -> Void) async throws {
        var copy = current
        mutate(&copy)
        guard copy != current else { return }
        current = copy
        continuations.forEach { $0.yield(copy) }
    }
}

@MainActor
final class StubAudioDeviceCatalog: AudioDeviceCatalog {
    var current: [AudioDevice]
    var continuations: [AsyncStream<[AudioDevice]>.Continuation] = []

    init(initial: [AudioDevice]) { self.current = initial }

    var devices: [AudioDevice] { get async { current } }

    var changes: AsyncStream<[AudioDevice]> {
        AsyncStream { continuation in
            continuation.yield(current)
            continuations.append(continuation)
        }
    }

    func setDevices(_ devices: [AudioDevice]) {
        current = devices
        continuations.forEach { $0.yield(devices) }
    }
}

@MainActor
final class StubKeychainAuth: KeychainAuth {
    var loggedIn: Bool = false
    var storedCookie: String?

    var isLoggedIn: Bool { loggedIn }
    func storeCookie(_ cookie: String) async throws {
        storedCookie = cookie
        loggedIn = true
    }
    func clearCookie() async throws {
        storedCookie = nil
        loggedIn = false
    }
}
```

The stubs are `@MainActor` to keep test reads simple. Cross-actor properties on the protocol need to compile clean against `Sendable`-tagged protocols — confirm by building.

- [ ] **Step 4: Implement the bare scaffold**

`Sources/RPPlayer/Shell/SettingsViewModel.swift`:

```swift
import Combine
import Foundation

@MainActor
final class SettingsViewModel: ObservableObject {
    @Published private(set) var selectedChannelId: Int
    @Published private(set) var bitrate: Int
    @Published private(set) var hogModeEnabled: Bool
    @Published private(set) var softwareVolumeEnabled: Bool
    @Published private(set) var notificationsEnabled: Bool
    @Published private(set) var outputDeviceUID: String?
    @Published private(set) var devices: [AudioDevice] = []
    @Published private(set) var isSignedIn: Bool = false

    private let configStore: any ConfigStore
    private let deviceCatalog: any AudioDeviceCatalog
    private let auth: any KeychainAuth
    private let openLoginWindowAction: @MainActor () -> Void
    private let openDataFolderAction: @MainActor () -> Void
    private let openLogsFolderAction: @MainActor () -> Void

    private var configTask: Task<Void, Never>?
    private var deviceTask: Task<Void, Never>?

    init(
        configStore: any ConfigStore,
        deviceCatalog: any AudioDeviceCatalog,
        auth: any KeychainAuth,
        openLoginWindow: @escaping @MainActor () -> Void,
        openDataFolder: @escaping @MainActor () -> Void,
        openLogsFolder: @escaping @MainActor () -> Void
    ) {
        self.configStore = configStore
        self.deviceCatalog = deviceCatalog
        self.auth = auth
        self.openLoginWindowAction = openLoginWindow
        self.openDataFolderAction = openDataFolder
        self.openLogsFolderAction = openLogsFolder

        let snapshot = AppSettings.default
        self.selectedChannelId = snapshot.selectedChannelId
        self.bitrate = snapshot.bitrate
        self.hogModeEnabled = snapshot.hogModeEnabled
        self.softwareVolumeEnabled = snapshot.softwareVolumeEnabled
        self.notificationsEnabled = snapshot.notificationsEnabled
        self.outputDeviceUID = snapshot.outputDeviceUID
    }
}
```

- [ ] **Step 5: Run, expect pass**

Run: `swift test --filter RPPlayerTests.SettingsViewModelTests`
Expected: 1 test passes.

- [ ] **Step 6: Add start/stop + subscription tests**

Append to `SettingsViewModelTests`:

```swift
    func testStartAdoptsConfigStoreSnapshotAndDeviceCatalog() async throws {
        var seed = AppSettings.default
        seed.bitrate = 2
        seed.hogModeEnabled = false
        configStore = StubConfigStore(initial: seed)
        let device = AudioDevice(
            name: "Probe DAC", uid: "uid-1",
            transportType: .usb, isBitPerfectRecommended: true
        )
        deviceCatalog = StubAudioDeviceCatalog(initial: [device])
        sut = SettingsViewModel(
            configStore: configStore, deviceCatalog: deviceCatalog, auth: auth,
            openLoginWindow: { }, openDataFolder: { }, openLogsFolder: { }
        )

        await sut.start()
        try await Task.sleep(nanoseconds: 50_000_000)

        XCTAssertEqual(sut.bitrate, 2)
        XCTAssertFalse(sut.hogModeEnabled)
        XCTAssertEqual(sut.devices.map(\.uid), ["uid-1"])
    }

    func testStartReflectsAuthState() async throws {
        auth.loggedIn = true
        await sut.start()
        XCTAssertTrue(sut.isSignedIn)
    }
```

- [ ] **Step 7: Run, expect fail**

Run: `swift test --filter RPPlayerTests.SettingsViewModelTests`
Expected: `start()` undefined.

- [ ] **Step 8: Implement `start()` / `stop()`**

```swift
    func start() async {
        await stop()
        let configStream = await configStore.changes
        configTask = Task { [weak self] in
            for await snapshot in configStream {
                guard let self else { return }
                if Task.isCancelled { return }
                await MainActor.run {
                    self.selectedChannelId = snapshot.selectedChannelId
                    self.bitrate = snapshot.bitrate
                    self.hogModeEnabled = snapshot.hogModeEnabled
                    self.softwareVolumeEnabled = snapshot.softwareVolumeEnabled
                    self.notificationsEnabled = snapshot.notificationsEnabled
                    self.outputDeviceUID = snapshot.outputDeviceUID
                }
            }
        }
        let deviceStream = await deviceCatalog.changes
        deviceTask = Task { [weak self] in
            for await devices in deviceStream {
                guard let self else { return }
                if Task.isCancelled { return }
                await MainActor.run { self.devices = devices }
            }
        }
        isSignedIn = auth.isLoggedIn
    }

    func stop() async {
        configTask?.cancel()
        configTask = nil
        deviceTask?.cancel()
        deviceTask = nil
    }
```

- [ ] **Step 9: Run, expect 3 tests pass**

Run: `swift test --filter RPPlayerTests.SettingsViewModelTests`

- [ ] **Step 10: Add mutation tests**

Append:

```swift
    func testSetBitratePersistsToConfigStore() async throws {
        await sut.start()
        await sut.setBitrate(2)
        try await Task.sleep(nanoseconds: 50_000_000)
        let stored = await configStore.settings
        XCTAssertEqual(stored.bitrate, 2)
        XCTAssertEqual(sut.bitrate, 2)
    }

    func testToggleHogModeFlipsBoth() async throws {
        await sut.start()
        await sut.setHogModeEnabled(false)
        try await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertFalse(sut.hogModeEnabled)
        let stored = await configStore.settings
        XCTAssertFalse(stored.hogModeEnabled)
    }

    func testSetOutputDeviceUIDPersistsAndRoundTrips() async throws {
        await sut.start()
        await sut.setOutputDeviceUID("uid-2")
        try await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertEqual(sut.outputDeviceUID, "uid-2")
        let stored = await configStore.settings
        XCTAssertEqual(stored.outputDeviceUID, "uid-2")
    }

    func testSignOutCallsKeychainClearAndUpdatesIsSignedIn() async throws {
        auth.loggedIn = true
        await sut.start()
        XCTAssertTrue(sut.isSignedIn)

        await sut.signOut()

        XCTAssertFalse(sut.isSignedIn)
        XCTAssertFalse(auth.loggedIn)
    }

    func testOpenLoginWindowInvokesInjectedClosure() {
        var calls = 0
        sut = SettingsViewModel(
            configStore: configStore, deviceCatalog: deviceCatalog, auth: auth,
            openLoginWindow: { calls += 1 },
            openDataFolder: { }, openLogsFolder: { }
        )
        sut.openLoginWindow()
        XCTAssertEqual(calls, 1)
    }

    func testOpenDataFolderAndLogsFolderInvokeInjectedClosures() {
        var dataCalls = 0
        var logsCalls = 0
        sut = SettingsViewModel(
            configStore: configStore, deviceCatalog: deviceCatalog, auth: auth,
            openLoginWindow: { },
            openDataFolder: { dataCalls += 1 },
            openLogsFolder: { logsCalls += 1 }
        )
        sut.openDataFolder()
        sut.openLogsFolder()
        XCTAssertEqual(dataCalls, 1)
        XCTAssertEqual(logsCalls, 1)
    }
```

- [ ] **Step 11: Add the mutation methods to `SettingsViewModel`**

```swift
    func setBitrate(_ value: Int) async {
        await update { $0.bitrate = value }
    }

    func setHogModeEnabled(_ value: Bool) async {
        await update { $0.hogModeEnabled = value }
    }

    func setSoftwareVolumeEnabled(_ value: Bool) async {
        await update { $0.softwareVolumeEnabled = value }
    }

    func setNotificationsEnabled(_ value: Bool) async {
        await update { $0.notificationsEnabled = value }
    }

    func setOutputDeviceUID(_ value: String?) async {
        await update { $0.outputDeviceUID = value }
    }

    func signOut() async {
        try? await auth.clearCookie()
        isSignedIn = auth.isLoggedIn
    }

    func openLoginWindow() { openLoginWindowAction() }
    func openDataFolder() { openDataFolderAction() }
    func openLogsFolder() { openLogsFolderAction() }

    func refreshAuthState() {
        isSignedIn = auth.isLoggedIn
    }

    private func update(_ mutate: @Sendable (inout AppSettings) -> Void) async {
        try? await configStore.update(mutate)
    }
```

`refreshAuthState()` exists so the AppDelegate can poke the model after the login window closes. The view's `.task` calls `start()`; the AppDelegate hooks into the login flow's completion to call `refreshAuthState()`.

- [ ] **Step 12: Run, expect 9 tests pass**

Run: `swift test --filter RPPlayerTests.SettingsViewModelTests`
Expected: 9 tests pass total.

- [ ] **Step 13: Commit**

```bash
git add Sources/RPPlayer/Shell/SettingsViewModel.swift \
        Tests/RPPlayerTests/Shell/SettingsViewModelTests.swift
git commit -m "feat(pr10): SettingsViewModel bridging ConfigStore + DeviceCatalog + KeychainAuth"
```

---

## Task 2: `SettingsView` SwiftUI

**Files:**
- Create: `Sources/RPPlayer/Shell/SettingsView.swift`
- Create: `Tests/RPPlayerTests/Shell/SettingsViewTests.swift`

A SwiftUI `Form` with four sections (Audio, Notifications, Account, Data). Each row binds to the model.

- [ ] **Step 1: Write failing render test**

`Tests/RPPlayerTests/Shell/SettingsViewTests.swift`:

```swift
import AppKit
import SwiftUI
import XCTest
@testable import RPPlayer

@MainActor
final class SettingsViewTests: XCTestCase {
    func testHostingControllerRendersWithoutCrash() {
        let viewModel = SettingsViewModel(
            configStore: StubConfigStore(initial: AppSettings.default),
            deviceCatalog: StubAudioDeviceCatalog(initial: []),
            auth: StubKeychainAuth(),
            openLoginWindow: { },
            openDataFolder: { },
            openLogsFolder: { }
        )
        let host = NSHostingController(rootView: SettingsView(viewModel: viewModel))
        host.loadView()
        XCTAssertNotNil(host.view)
        XCTAssertGreaterThan(host.view.intrinsicContentSize.width, 0)
    }
}
```

The stubs `StubConfigStore`, `StubAudioDeviceCatalog`, `StubKeychainAuth` are reused from `SettingsViewModelTests`. Either hoist them to `Tests/RPPlayerTests/Shell/SettingsTestStubs.swift` (cleanest) OR re-declare as private types inside this file. The plan picks **hoist** because Tasks 3 and 4 also reference them.

- [ ] **Step 2: Hoist the stubs**

Move `StubConfigStore`, `StubAudioDeviceCatalog`, `StubKeychainAuth` from `SettingsViewModelTests.swift` into a new `Tests/RPPlayerTests/Shell/SettingsTestStubs.swift`. Make them `final class` (not `private`) and remove the `@MainActor` if any future cross-test reads cross actor boundaries. Re-run the existing 9 tests to confirm no regression.

- [ ] **Step 3: Add `TransportType.label`**

Append to `Sources/RPPlayer/Player/AudioDevice.swift` (inside the existing `TransportType` enum or as a small extension):

```swift
extension TransportType {
    public var label: String {
        switch self {
        case .builtIn:      return "Built-in"
        case .usb:          return "USB"
        case .thunderbolt:  return "Thunderbolt"
        case .hdmi:         return "HDMI"
        case .bluetooth:    return "Bluetooth"
        case .airplay:      return "AirPlay"
        case .unknown:      return "Unknown"
        }
    }
}
```

Confirm `swift test --filter RPPlayerTests.TransportTypeTests` still passes (PR 4 tests don't assert on labels).

- [ ] **Step 4: Implement the view**

`Sources/RPPlayer/Shell/SettingsView.swift`:

```swift
import SwiftUI

struct SettingsView: View {
    @ObservedObject var viewModel: SettingsViewModel

    var body: some View {
        Form {
            audioSection
            notificationsSection
            accountSection
            dataSection
        }
        .formStyle(.grouped)
        .frame(width: 480, height: 560)
        .task { await viewModel.start() }
    }

    private var audioSection: some View {
        Section("Audio") {
            Picker("Output device", selection: deviceBinding) {
                Text("Select an output device").tag(String?.none)
                ForEach(viewModel.devices, id: \.uid) { device in
                    Text(deviceLabel(device)).tag(Optional(device.uid))
                }
            }
            Toggle("Hog mode (bit-perfect)", isOn: hogModeBinding)
            Toggle("Software volume control", isOn: softwareVolumeBinding)
            Picker("Bitrate", selection: bitrateBinding) {
                Text("AAC 64 kbps").tag(0)
                Text("AAC 128 kbps").tag(1)
                Text("MP3 320 kbps").tag(2)
                Text("FLAC (compressed)").tag(3)
                Text("FLAC (highest)").tag(4)
            }
        }
    }

    private var notificationsSection: some View {
        Section("Notifications") {
            Toggle("Show desktop notifications on song start", isOn: notificationsBinding)
        }
    }

    private var accountSection: some View {
        Section("Account") {
            HStack {
                Text(viewModel.isSignedIn ? "Signed in" : "Anonymous")
                Spacer()
                if viewModel.isSignedIn {
                    Button("Sign out") {
                        Task { await viewModel.signOut() }
                    }
                } else {
                    Button("Sign in") { viewModel.openLoginWindow() }
                }
            }
        }
    }

    private var dataSection: some View {
        Section("Data") {
            Button("Show data folder") { viewModel.openDataFolder() }
            Button("Show logs") { viewModel.openLogsFolder() }
        }
    }

    private func deviceLabel(_ device: AudioDevice) -> String {
        let suffix = device.transportType.isBitPerfectRecommended ? "" : " (not recommended for bit-perfect)"
        return "\(device.name) — \(device.transportType.label)\(suffix)"
    }

    private var deviceBinding: Binding<String?> {
        Binding(
            get: { viewModel.outputDeviceUID },
            set: { newValue in Task { await viewModel.setOutputDeviceUID(newValue) } }
        )
    }

    private var hogModeBinding: Binding<Bool> {
        Binding(
            get: { viewModel.hogModeEnabled },
            set: { newValue in Task { await viewModel.setHogModeEnabled(newValue) } }
        )
    }

    private var softwareVolumeBinding: Binding<Bool> {
        Binding(
            get: { viewModel.softwareVolumeEnabled },
            set: { newValue in Task { await viewModel.setSoftwareVolumeEnabled(newValue) } }
        )
    }

    private var notificationsBinding: Binding<Bool> {
        Binding(
            get: { viewModel.notificationsEnabled },
            set: { newValue in Task { await viewModel.setNotificationsEnabled(newValue) } }
        )
    }

    private var bitrateBinding: Binding<Int> {
        Binding(
            get: { viewModel.bitrate },
            set: { newValue in Task { await viewModel.setBitrate(newValue) } }
        )
    }
}
```

`TransportType.label` is the small enum-extension added in Step 3.

- [ ] **Step 5: Run, expect pass**

Run: `swift test --filter RPPlayerTests.SettingsViewTests`
Expected: 1 test passes.

- [ ] **Step 6: Run the full suite**

Run: `swift test`
Expected: existing 127 + 9 SettingsViewModelTests + 1 SettingsViewTests = 137. Confirm no regression.

- [ ] **Step 7: Commit**

```bash
git add Sources/RPPlayer/Shell/SettingsView.swift \
        Sources/RPPlayer/Player/AudioDevice.swift \
        Tests/RPPlayerTests/Shell/SettingsViewTests.swift \
        Tests/RPPlayerTests/Shell/SettingsTestStubs.swift \
        Tests/RPPlayerTests/Shell/SettingsViewModelTests.swift
git commit -m "feat(pr10): SettingsView SwiftUI form bound to SettingsViewModel"
```

---

## Task 3: `SettingsWindowController`

**Files:**
- Create: `Sources/RPPlayer/Shell/SettingsWindowController.swift`
- Create: `Tests/RPPlayerTests/Shell/SettingsWindowControllerTests.swift`

A `NSWindowController` that lazily constructs an `NSWindow` hosting `SettingsView` and exposes `show()` / `hide()`.

- [ ] **Step 1: Write failing test**

`Tests/RPPlayerTests/Shell/SettingsWindowControllerTests.swift`:

```swift
import AppKit
import SwiftUI
import XCTest
@testable import RPPlayer

@MainActor
final class SettingsWindowControllerTests: XCTestCase {
    func testInitConfiguresWindowFrameAndStyle() {
        let viewModel = SettingsViewModel(
            configStore: StubConfigStore(initial: AppSettings.default),
            deviceCatalog: StubAudioDeviceCatalog(initial: []),
            auth: StubKeychainAuth(),
            openLoginWindow: { }, openDataFolder: { }, openLogsFolder: { }
        )
        let sut = SettingsWindowController(viewModel: viewModel)
        let window = sut.window!
        XCTAssertTrue(window.styleMask.contains(.titled))
        XCTAssertTrue(window.styleMask.contains(.closable))
        XCTAssertEqual(window.contentView?.frame.size, NSSize(width: 480, height: 560))
        XCTAssertEqual(window.title, "Settings")
    }

    func testIsVisibleReflectsWindowVisibility() {
        let viewModel = SettingsViewModel(
            configStore: StubConfigStore(initial: AppSettings.default),
            deviceCatalog: StubAudioDeviceCatalog(initial: []),
            auth: StubKeychainAuth(),
            openLoginWindow: { }, openDataFolder: { }, openLogsFolder: { }
        )
        let sut = SettingsWindowController(viewModel: viewModel)
        XCTAssertFalse(sut.isVisible)
    }
}
```

- [ ] **Step 2: Run, expect failure**

Run: `swift test --filter RPPlayerTests.SettingsWindowControllerTests`
Expected: `SettingsWindowController` undefined.

- [ ] **Step 3: Implement**

`Sources/RPPlayer/Shell/SettingsWindowController.swift`:

```swift
import AppKit
import SwiftUI

@MainActor
final class SettingsWindowController: NSWindowController {
    static let contentSize = NSSize(width: 480, height: 560)

    init(viewModel: SettingsViewModel) {
        let hosting = NSHostingController(rootView: SettingsView(viewModel: viewModel))
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: Self.contentSize),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "Settings"
        window.contentViewController = hosting
        window.center()
        window.isReleasedWhenClosed = false
        super.init(window: window)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("use init(viewModel:)") }

    var isVisible: Bool { window?.isVisible ?? false }

    func show() {
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func hide() {
        window?.orderOut(nil)
    }
}
```

- [ ] **Step 4: Run, expect 2 tests pass**

Run: `swift test --filter RPPlayerTests.SettingsWindowControllerTests`

- [ ] **Step 5: Commit**

```bash
git add Sources/RPPlayer/Shell/SettingsWindowController.swift \
        Tests/RPPlayerTests/Shell/SettingsWindowControllerTests.swift
git commit -m "feat(pr10): SettingsWindowController hosting SettingsView"
```

---

## Task 4: `RatingRow` + `MiniPlayerViewModel.rate(_:)`

**Files:**
- Create: `Sources/RPPlayer/Shell/RatingRow.swift`
- Create: `Tests/RPPlayerTests/Shell/RatingRowTests.swift`
- Modify: `Sources/RPPlayer/Shell/MiniPlayerViewModel.swift`
- Modify: `Tests/RPPlayerTests/Shell/MiniPlayerViewModelTests.swift`

The view model gains `isSignedIn`, `currentRating`, `rate(_:)`, plus a `KeychainAuth` dependency. The view renders a 1–10 button row with "your rating" highlighting.

- [ ] **Step 1: Extend `MiniPlayerViewModel`**

Add stored properties:

```swift
    @Published private(set) var isSignedIn: Bool = false
    @Published private(set) var currentRating: Int?

    private let auth: any KeychainAuth
    private let openSettingsAction: @MainActor () -> Void
```

Update `init` (positional order: keep existing args, append `auth`, `openSettings`):

```swift
    init(
        coordinator: any PlaybackCoordinator,
        api: any RpApiClient,
        initialChannelId: Int,
        albumArtCache: any AlbumArtCache,
        auth: any KeychainAuth,
        openSettings: @escaping @MainActor () -> Void,
        persistChannelId: @escaping PersistChannelId = { _ in }
    ) {
        self.coordinator = coordinator
        self.api = api
        self.albumArtCache = albumArtCache
        self.auth = auth
        self.openSettingsAction = openSettings
        self.selectedChannelId = initialChannelId
        self.persistChannelId = persistChannelId
    }
```

Update the subscription `Task` body in `start()` so that on every `nowPlaying` emission it ALSO refreshes `isSignedIn` and `currentRating`:

```swift
    subscriptionTask = Task { [weak self] in
        for await np in stream {
            guard let self else { return }
            await MainActor.run {
                self.nowPlaying = np
                self.isPlaying = true
                self.currentArt = nil
                self.isSignedIn = self.auth.isLoggedIn
                self.currentRating = Self.parseRating(from: np.song.userRating)
            }
            await self.loadArt(for: np)
        }
    }
```

(`self.currentArt = nil` here addresses PR 9 review I2 — old art cleared the moment a new song arrives, so the user never sees song B's title with song A's art.)

Add the helper + new methods:

```swift
    func rate(_ value: Int) async {
        guard isSignedIn,
              let np = nowPlaying,
              let songId = Int(np.song.songId)
        else { return }
        do {
            errorMessage = nil
            _ = try await api.rate(songId: songId, rating: value)
            currentRating = value
        } catch {
            errorMessage = "Rating failed: \(error.localizedDescription)"
        }
    }

    func openSettings() {
        openSettingsAction()
    }

    func refreshAuthState() {
        isSignedIn = auth.isLoggedIn
    }

    private static func parseRating(from raw: String?) -> Int? {
        guard let raw, let value = Int(raw) else { return nil }
        return (1...10).contains(value) ? value : nil
    }
```

`refreshAuthState()` is called by `AppDelegate` after the login window closes.

- [ ] **Step 2: Update existing `MiniPlayerViewModelTests` setUp**

Every existing call site of `MiniPlayerViewModel(...)` in `MiniPlayerViewModelTests.swift` (and `MiniPlayerViewTests.swift`, `AppDelegateTests.swift`) needs updating to pass `auth: StubKeychainAuth()` and `openSettings: { }`. Add `auth` and `openSettings` to setUp:

```swift
    private var auth: StubKeychainAuth!
    private var openSettingsCalls = 0
    // ... in setUp:
    auth = StubKeychainAuth()
    openSettingsCalls = 0
    sut = MiniPlayerViewModel(
        coordinator: coordinator,
        api: api,
        initialChannelId: 0,
        albumArtCache: StubAlbumArtCache(),
        auth: auth,
        openSettings: { [unowned self] in self.openSettingsCalls += 1 }
    )
```

The previous 13 tests still pass; the openSettings count is for new tests.

- [ ] **Step 3: Add new view-model tests**

```swift
    func testIsSignedInTracksKeychainOnNowPlaying() async throws {
        auth.loggedIn = true
        await sut.start()
        await coordinator.setNowPlaying(NowPlaying.fixture(userRating: "7"))
        try await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertTrue(sut.isSignedIn)
        XCTAssertEqual(sut.currentRating, 7)
    }

    func testRateNoOpsWhenSignedOut() async throws {
        auth.loggedIn = false
        await sut.start()
        await coordinator.setNowPlaying(NowPlaying.fixture())
        try await Task.sleep(nanoseconds: 50_000_000)

        await sut.rate(8)
        let calls = await api.calls
        XCTAssertFalse(calls.contains(where: { if case .rate = $0 { return true } else { return false } }))
    }

    func testRateCallsApiAndUpdatesCurrentRatingWhenSignedIn() async throws {
        auth.loggedIn = true
        api.ratingResponse = Rating(status: "ok", songId: nil, userId: nil, userRating: nil)
        await sut.start()
        await coordinator.setNowPlaying(NowPlaying.fixture(songId: "61209"))
        try await Task.sleep(nanoseconds: 50_000_000)

        await sut.rate(9)

        let calls = await api.calls
        XCTAssertTrue(calls.contains(.rate(songId: 61209, rating: 9)))
        XCTAssertEqual(sut.currentRating, 9)
    }

    func testRateSurfacesErrorAndDoesNotUpdateRating() async throws {
        auth.loggedIn = true
        api.rateError = RpApiError.network(URLError(.notConnectedToInternet))
        await sut.start()
        await coordinator.setNowPlaying(NowPlaying.fixture(songId: "1"))
        try await Task.sleep(nanoseconds: 50_000_000)

        await sut.rate(5)

        XCTAssertNotNil(sut.errorMessage)
        XCTAssertNil(sut.currentRating)
    }

    func testCurrentArtClearsImmediatelyOnNowPlayingChange() async throws {
        let cache = StubAlbumArtCache()
        cache.imageByPath["covers/l/a.jpg"] = NSImage(size: NSSize(width: 1, height: 1))
        sut = MiniPlayerViewModel(
            coordinator: coordinator, api: api, initialChannelId: 0,
            albumArtCache: cache, auth: auth, openSettings: { }
        )
        await sut.start()
        await coordinator.setNowPlaying(NowPlaying.fixture(cover: "covers/l/a.jpg"))
        try await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertNotNil(sut.currentArt)

        await coordinator.setNowPlaying(NowPlaying.fixture(cover: nil))
        // currentArt should clear synchronously inside the MainActor.run hop,
        // before loadArt(for:) returns.
        try await Task.sleep(nanoseconds: 10_000_000)
        XCTAssertNil(sut.currentArt)
    }

    func testOpenSettingsInvokesInjectedClosure() {
        sut.openSettings()
        XCTAssertEqual(openSettingsCalls, 1)
    }
```

The `NowPlaying.fixture(...)` extension already lives in `Tests/RPPlayerTests/Playback/NowPlayingFixture.swift` (PR 9 hoist). Extend it:

```swift
public extension NowPlaying {
    static func fixture(
        title: String = "Title",
        artist: String = "Artist",
        album: String = "Album",
        cover: String? = nil,
        userRating: String? = nil,
        songId: String = "1"
    ) -> NowPlaying {
        // ... existing body, plus pass userRating + songId into PlayListSong ...
    }
}
```

Update `MockRpApiClient` to expose a `rateError: Error?` (mirrors the PR 9 `listChannelsError`) plus a `setRateError(_:)` setter so the rate-error test can inject a failure:

```swift
var rateError: Error?

func setRateError(_ error: Error) { rateError = error }

func rate(songId: Int, rating: Int) async throws -> Rating {
    calls.append(.rate(songId: songId, rating: rating))
    if let error = rateError { throw error }
    return ratingResponse
}
```

- [ ] **Step 4: Run, expect pass**

Run: `swift test --filter RPPlayerTests.MiniPlayerViewModelTests`
Expected: 18 tests pass (was 13; +5 new). Verify the existing 13 still pass.

- [ ] **Step 5: Implement `RatingRow`**

`Sources/RPPlayer/Shell/RatingRow.swift`:

```swift
import SwiftUI

struct RatingRow: View {
    let currentRating: Int?
    let isSignedIn: Bool
    let onRate: (Int) -> Void

    var body: some View {
        VStack(spacing: 4) {
            HStack(spacing: 6) {
                ForEach(1...10, id: \.self) { value in
                    Button {
                        onRate(value)
                    } label: {
                        Text("\(value)")
                            .font(.caption.monospacedDigit())
                            .frame(width: 22, height: 22)
                            .background(background(for: value))
                            .clipShape(Circle())
                    }
                    .buttonStyle(.plain)
                    .disabled(!isSignedIn)
                    .accessibilityLabel("Rate \(value)")
                }
            }
            if !isSignedIn {
                Text("Sign in to rate")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func background(for value: Int) -> some ShapeStyle {
        if let currentRating, value <= currentRating {
            return AnyShapeStyle(Color.accentColor.opacity(0.6))
        }
        return AnyShapeStyle(Color.secondary.opacity(0.15))
    }
}
```

- [ ] **Step 6: Add a render test**

`Tests/RPPlayerTests/Shell/RatingRowTests.swift`:

```swift
import AppKit
import SwiftUI
import XCTest
@testable import RPPlayer

@MainActor
final class RatingRowTests: XCTestCase {
    func testHostingControllerRendersWithoutCrash() {
        var rated: [Int] = []
        let host = NSHostingController(
            rootView: RatingRow(currentRating: 7, isSignedIn: true) { rated.append($0) }
        )
        host.loadView()
        XCTAssertNotNil(host.view)
        XCTAssertGreaterThan(host.view.intrinsicContentSize.width, 0)
    }
}
```

- [ ] **Step 7: Insert `RatingRow` into `MiniPlayerView`**

In `MiniPlayerView.swift`, add a gear button in a top toolbar HStack and the rating row below the metadata. Replace the `body`'s top-level VStack to add the gear button and rating row:

```swift
    var body: some View {
        VStack(spacing: 12) {
            HStack {
                Spacer()
                Button {
                    viewModel.openSettings()
                } label: {
                    Image(systemName: "gearshape")
                        .font(.system(size: 14, weight: .regular))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Settings")
            }
            artwork
            metadata
            transport
            channelPicker
            RatingRow(
                currentRating: viewModel.currentRating,
                isSignedIn: viewModel.isSignedIn
            ) { value in
                Task { await viewModel.rate(value) }
            }
            if let message = viewModel.errorMessage {
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .multilineTextAlignment(.center)
            }
        }
        .frame(width: 320, height: 540)
        .padding()
        .task { await viewModel.start() }
    }
```

The popover height bumps to 540 to fit the rating row + gear. Update `PopoverController.contentSize` to match:

```swift
    static let contentSize = NSSize(width: 320, height: 540)
```

`MiniPlayerViewTests.testHostingControllerRendersWithoutCrash` already exercises the new view tree; verify it still passes.

- [ ] **Step 8: Run, expect pass**

Run: `swift test --filter "RPPlayerTests.RatingRowTests|RPPlayerTests.MiniPlayerViewModelTests|RPPlayerTests.MiniPlayerViewTests|RPPlayerTests.PopoverControllerTests"`
Expected: all green.

Run full suite. Expected count: previous + 5 view-model + 1 rating-row = +6 net (the existing tests in `MiniPlayerViewTests` + `PopoverControllerTests` keep counting as-is). 137 → 143.

- [ ] **Step 9: Commit**

```bash
git add Sources/RPPlayer/Shell/RatingRow.swift \
        Sources/RPPlayer/Shell/MiniPlayerView.swift \
        Sources/RPPlayer/Shell/MiniPlayerViewModel.swift \
        Sources/RPPlayer/Shell/PopoverController.swift \
        Tests/RPPlayerTests/Shell/RatingRowTests.swift \
        Tests/RPPlayerTests/Shell/MiniPlayerViewModelTests.swift \
        Tests/RPPlayerTests/Playback/NowPlayingFixture.swift \
        Tests/RPPlayerTests/Playback/MockRpApiClient.swift
git commit -m "feat(pr10): rating row + sign-in tracking + gear button to settings"
```

---

## Task 5: PR 9 review carry-over — gate Esc monitor on popover window

**Files:**
- Modify: `Sources/RPPlayer/Shell/PopoverController.swift`

The PR 9 review flagged that the local Esc monitor is process-wide. PR 10 introduces `SettingsWindowController` (a non-popover window), so Esc inside Settings would dismiss the popover. Gate the monitor.

- [ ] **Step 1: Update the local key monitor**

In `PopoverController.installMonitors`, change the local key monitor closure to early-return `event` (do not consume) when the event's window is NOT the popover's panel:

```swift
        if localKeyMonitor == nil {
            localKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                guard let self, event.window === self.panel else { return event }
                if event.keyCode == Self.escapeKeyCode {
                    Task { @MainActor [weak self] in
                        self?.close()
                    }
                    return nil
                }
                return event
            }
        }
```

`Self.escapeKeyCode` is the named constant from PR 7 polish. The `guard ... event.window === self.panel` clause means key events directed at any other window (Settings, Login) pass through unchanged.

- [ ] **Step 2: Build + run**

Run: `swift build` → clean.
Run: `swift test --filter RPPlayerTests.PopoverControllerTests` → existing 2 tests still pass (they don't fire keystrokes; the change is observable only via manual smoke).

- [ ] **Step 3: Commit**

```bash
git add Sources/RPPlayer/Shell/PopoverController.swift
git commit -m "fix(pr10): scope popover Esc-dismiss monitor to the popover window"
```

---

## Task 6: `AppDelegate` wiring (KeychainCookieProvider, settings window, login window)

**Files:**
- Modify: `Sources/RPPlayer/Shell/AppDelegate.swift`
- Modify: `Tests/RPPlayerTests/Shell/AppDelegateTests.swift`

`realBootstrap` swaps `AnonymousCookieProvider` for `KeychainCookieProvider`, constructs the `LoginWindowController` + `SettingsWindowController`, and pipes their open/close hooks into the view models.

- [ ] **Step 1: Extend `Bootstrap`**

```swift
    struct Bootstrap {
        let viewModel: MiniPlayerViewModel
        let settingsViewModel: SettingsViewModel
        let notificationCoordinator: NotificationCoordinator
        let settingsWindowController: SettingsWindowController
        let loginWindowController: LoginWindowController
        let coordinatorShutdown: @Sendable () async -> Void
    }
```

Retain `settingsViewModel`, `settingsWindowController`, `loginWindowController` on the delegate so they outlive `applicationDidFinishLaunching`.

- [ ] **Step 2: Rewrite `realBootstrap` (relevant section only)**

```swift
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

        let keychainAuth = KeychainCookieProvider()  // default SecItemKeychainStore
        let api = LiveRpApiClient(cookieProvider: keychainAuth, logger: logger)

        // ... cache, engine, coordinator, notification service unchanged ...

        let deviceCatalog = CoreAudioDeviceCatalog()

        let loginWindowController = LoginWindowController(keychainAuth: keychainAuth)

        // forward declarations needed because the closures cross-reference each other
        var settingsWindowControllerRef: SettingsWindowController?
        var miniViewModelRef: MiniPlayerViewModel?

        let settingsViewModel = SettingsViewModel(
            configStore: store ?? UnreachableConfigStore(),
            deviceCatalog: deviceCatalog,
            auth: keychainAuth,
            openLoginWindow: { [loginWindowController] in
                loginWindowController.show()
            },
            openDataFolder: {
                NSWorkspace.shared.open(ConfigPaths.applicationSupportRoot)
            },
            openLogsFolder: {
                NSWorkspace.shared.open(ConfigPaths.logsDirectory)
            }
        )

        let settingsWindowController = SettingsWindowController(viewModel: settingsViewModel)
        settingsWindowControllerRef = settingsWindowController

        let viewModel = MiniPlayerViewModel(
            coordinator: coordinator,
            api: api,
            initialChannelId: initial.selectedChannelId,
            albumArtCache: cache,
            auth: keychainAuth,
            openSettings: { [settingsWindowController] in
                settingsWindowController.show()
            },
            persistChannelId: { id in
                guard let store else { return }
                try? await store.update { $0.selectedChannelId = id }
            }
        )
        miniViewModelRef = viewModel

        // After login window closes, both view models refresh sign-in state.
        // The login window writes the cookie + closes itself; we observe via
        // NSWindowDelegate. Add a small bridge:
        let bridge = LoginCloseBridge(
            onClose: { [miniViewModelRef, settingsViewModel] in
                miniViewModelRef?.refreshAuthState()
                settingsViewModel.refreshAuthState()
            }
        )
        loginWindowController.window?.delegate = bridge

        // ... NotificationCoordinator and authorization Task unchanged ...

        return Bootstrap(
            viewModel: viewModel,
            settingsViewModel: settingsViewModel,
            notificationCoordinator: notificationCoordinator,
            settingsWindowController: settingsWindowController,
            loginWindowController: loginWindowController,
            coordinatorShutdown: { await coordinator.shutdown() }
        )
    }
```

`UnreachableConfigStore` is a tiny private fallback type that crashes on any access, used only when the real store fails to open (production should never hit this). Or, simpler: skip the `??` and propagate the optional further down — but every consumer expects a non-optional `ConfigStore`, so keeping the unreachable fallback isolates the failure to the moment of use. Pick whichever is cleaner during implementation.

`LoginCloseBridge` is a small `NSObject`-derived class implementing `NSWindowDelegate.windowWillClose(_:)` to call the supplied closure. Inline private type in `AppDelegate.swift`.

- [ ] **Step 3: Update `AppDelegateTests`**

The `setUp` bootstrap closure expands to include the new fields. Add stub `LoginWindowController` / `SettingsWindowController`? Both can be constructed in tests with the same view models but the real Login window — actually the LoginWindowController real constructor needs a `KeychainAuth`. Since tests already pass `auth: StubKeychainAuth()`, building a real `LoginWindowController(keychainAuth: auth)` should work and the window simply isn't shown. The test never calls `.show()`.

Wrap test setUp:

```swift
    override func setUp() async throws {
        delegate = AppDelegate(bootstrap: {
            let coordinator = MockPlaybackCoordinator()
            let api = MockRpApiClient()
            let cache = StubAlbumArtCache()
            let service = MockNotificationService()
            let auth = StubKeychainAuth()
            let configStore = StubConfigStore(initial: AppSettings.default)
            let deviceCatalog = StubAudioDeviceCatalog(initial: [])

            let settingsViewModel = SettingsViewModel(
                configStore: configStore, deviceCatalog: deviceCatalog, auth: auth,
                openLoginWindow: { }, openDataFolder: { }, openLogsFolder: { }
            )
            let viewModel = MiniPlayerViewModel(
                coordinator: coordinator, api: api, initialChannelId: 0,
                albumArtCache: cache, auth: auth, openSettings: { }
            )
            let notificationCoordinator = NotificationCoordinator(
                coordinator: coordinator, cache: cache, service: service,
                notificationsEnabled: { false }, channelTitle: { _ in nil }, cachedFileURL: { _ in nil }
            )
            let loginWindowController = LoginWindowController(keychainAuth: auth)
            let settingsWindowController = SettingsWindowController(viewModel: settingsViewModel)
            return AppDelegate.Bootstrap(
                viewModel: viewModel,
                settingsViewModel: settingsViewModel,
                notificationCoordinator: notificationCoordinator,
                settingsWindowController: settingsWindowController,
                loginWindowController: loginWindowController,
                coordinatorShutdown: { await coordinator.shutdown() }
            )
        })
    }
```

The existing 2 tests should still pass. Add a 3rd: `testApplicationWillTerminateClosesSettingsWindow` if useful — optional, plan does not require it.

- [ ] **Step 4: Build + run**

Run: `swift build` → clean.
Run: `swift test --filter RPPlayerTests.AppDelegateTests` → 2 tests pass.
Run: `swift test` → all green.

- [ ] **Step 5: Commit**

```bash
git add Sources/RPPlayer/Shell/AppDelegate.swift \
        Tests/RPPlayerTests/Shell/AppDelegateTests.swift
git commit -m "feat(pr10): wire KeychainCookieProvider + settings window + login window"
```

---

## Task 7: Polish + manual smoke + CLAUDE.md + merge

- [ ] **Step 1: Comment audit + build clean**

Walk every `//` introduced in PR 10. Each must encode a non-obvious WHY. Strip otherwise.

Run `swift build` — clean, no warnings beyond pre-existing LoginWindow `getAllCookies` warning.

- [ ] **Step 2: Run full suite**

Run: `swift test`
Expected: 127 + 9 settings-vm + 1 settings-view + 2 settings-window + 5 viewmodel-extension + 1 rating-row = +18, totalling 145. Adjust CLAUDE.md to match the actual count.

- [ ] **Step 3: Manual smoke**

Run: `swift run RPPlayer`

Confirm:
- Menu-bar icon → click → popover.
- Click gear → settings window opens (480×560, "Settings" title).
- Audio section: device picker lists detected devices with bus-type labels; toggles work; bitrate picker persists.
- Notifications section: toggle persists across launches.
- Account section: "Anonymous" + "Sign in" button. Click "Sign in" → login window opens (existing PR 3 webview).
- Sign in (use a real RP account or skip if you don't have one). After successful login, the login window closes; the next song boundary should cause `MiniPlayerView`'s rating row to enable + show your stored rating.
- Click a rating button → rating row highlights. Verify the API call was made by watching `Console.app` filtered on `RPPlayer`.
- Sign out from Settings → Account flips back to "Anonymous"; rating row disables on next song boundary.
- Data section: "Show data folder" → Finder opens `~/Library/Application Support/RP Player`. "Show logs" → opens `~/Library/Logs/RP Player`.
- Close settings window → popover still works.
- Esc inside Settings does NOT dismiss the popover (Task 5 fix).

If any visible smoke point fails, STOP and report.

- [ ] **Step 4: Update `CLAUDE.md`**

Flip PR 10 to ✅; mark PR 11 as next:

```markdown
| 10 | merged to main | ✅ | SettingsView + rating row + KeychainCookieProvider + login flow |
| 11 | **next** | ⬜ | AppContainer (composition root) |
```

Replace the "PR 9 shipped scope" paragraph with PR 10's. Append the new test count. Append new key-decision entries:

```markdown
- `SettingsViewModel` is `@MainActor final class: ObservableObject`. Subscriptions to `ConfigStore.changes` and `AudioDeviceCatalog.changes` are spawned in `start()`, never `init`. Closure-injected actions (`openLoginWindow`, `openDataFolder`, `openLogsFolder`) keep the model decoupled from AppKit / `NSWorkspace`.
- `SettingsWindowController` is a single-instance `NSWindowController` with `[.titled, .closable]` style; the window is reused across show/hide cycles. The window is a regular AppKit window, NOT a borderless panel, so it can take focus, receive Esc/Cmd-W, and be moved.
- The popover's local Esc monitor now gates on `event.window === panel`, so Esc inside the new Settings window doesn't dismiss the popover. Without this gate, Settings would be unusable while the popover was open.
- `MiniPlayerViewModel.isSignedIn` is refreshed on every `nowPlaying` emission (as well as via an explicit `refreshAuthState()` poke from the AppDelegate after the login window closes). There is no streaming auth-state observer; the keychain is read on demand, which is sufficient because login is rare and song boundaries fire often enough.
- `MiniPlayerViewModel.rate(_:)` is a no-op when `isSignedIn == false`. Anonymous rate calls succeed server-side but have no effect, so the gate avoids a wasted network round-trip and keeps the UX honest.
- `KeychainCookieProvider` is now wired into `realBootstrap` instead of `AnonymousCookieProvider`. Every authenticated request automatically picks up the keychain cookie. Sign-out via `KeychainAuth.clearCookie()` invalidates the cookie immediately; the next API call will be anonymous. PR 12's distribution `.app` will codesign the executable, which is what unlocks `kSecUseDataProtectionKeychain` (until then the existing keychain access pattern stays untouched per the existing CLAUDE.md note).
- `MiniPlayerViewModel` clears `currentArt` synchronously inside the `MainActor.run` hop on every `nowPlaying` emission, so the user never sees song B's title alongside song A's art. The cache fetch happens immediately after; the placeholder shows for the few hundred ms it takes to download the new cover.
```

- [ ] **Step 5: Commit + merge**

```bash
git add CLAUDE.md
git commit -m "docs(pr10): record settings + rating + login decisions and post-PR10 test count"
```

Then fast-forward merge to `main` from `/Users/gergely/git/rp-player`.

---

## Self-review checklist

- **Spec coverage:** every PR 10 row item ("SettingsView + rating row") implemented or explicitly deferred. Account section + LoginWindowController integration land in this PR per the original CLAUDE.md commitment to pair them.
- **PR 9 review carry-over:** I2 (clear `currentArt` on flip) ✅. Esc-monitor scope gate ✅. M1 (`MockAlbumArtCache` vs `StubAlbumArtCache` divergence) — not addressed in this PR, surface in PR 11. `LocalizedError` for other error types — out of scope.
- **Comment policy:** every `//` line explains a non-obvious WHY.
- **Test count math:** previous = 127, expected new ≈ 145 (+18). Adjust CLAUDE.md to actual.
- **No regression:** `swift build` clean, `swift test` 100% pass, manual smoke green for visible behavior.
- **Plan-vs-shipped drift:** record any compile-time deviations in an "Implementation deviations" section before merging (PR 9's pattern).

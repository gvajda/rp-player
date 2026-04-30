# PR 8 — MiniPlayerView Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the popover placeholder with a functional `MiniPlayerView` that displays the currently-playing song, lets the user play/pause, skip forward, and switch channels. Wire `AppDelegate` to a real `LivePlaybackCoordinator + LiveRpApiClient + LibmpvPlayerEngine` so the popover talks to actual playback. Carry over the two PR 7 follow-ups the reviewer flagged for this PR (Esc-to-dismiss, move `NSApp.activate` into the popover).

**Architecture:** A `@MainActor`, `final class: ObservableObject` `MiniPlayerViewModel` bridges `PlaybackCoordinator.nowPlayingUpdates` (an `AsyncStream<NowPlaying>`) to `@Published` UI state and forwards user intents (play/pause/skip/changeChannel) to the coordinator. `MiniPlayerView` (SwiftUI) renders the model and owns no playback logic. `PopoverController` swaps its hosted view from `AppShellPlaceholderView` to `MiniPlayerView` and accepts the view model as an init parameter. `AppDelegate.applicationDidFinishLaunching` builds the dependency graph inline (api → engine → coordinator → view model → popover); PR 11 (`AppContainer`) refactors that wiring out into a dedicated composition root. The placeholder view + tests are deleted.

**Tech Stack:** Swift 6.2, SwiftUI, AppKit, Combine via `ObservableObject` (the `@Observable` macro requires macOS 14; we target macOS 13). XCTest + the existing `MockPlaybackCoordinator` and `MockRpApiClient` test doubles.

---

## File structure

**Created**

- `Sources/RPPlayer/Shell/MiniPlayerViewModel.swift` — `@MainActor final class MiniPlayerViewModel: ObservableObject`. `@Published` properties: `nowPlaying: NowPlaying?`, `isPlaying: Bool`, `channels: [Channel]`, `selectedChannelId: Int`, `errorMessage: String?`. Methods: `start()`, `stop()`, `togglePlayPause()`, `skipForward()`, `selectChannel(_:)`. Owns the subscription `Task` and listChannels prefetch.
- `Sources/RPPlayer/Shell/MiniPlayerView.swift` — SwiftUI view with: 200×200 album-art placeholder area, two text rows (title, artist · album), one channel row (channel title), play/pause + skip-forward HStack, channel `Picker`. Settings + rating row are deliberately omitted (PR 9 / PR 10).
- `Tests/RPPlayerTests/Shell/MiniPlayerViewModelTests.swift`
- `Tests/RPPlayerTests/Shell/MiniPlayerViewTests.swift`

**Modified**

- `Sources/RPPlayer/Shell/PopoverController.swift` — accept an `AnyView` root in init (`init(rootView:)`) so the controller no longer hard-codes `AppShellPlaceholderView`; install/remove a local key-down monitor that closes on Esc (PR 7 review M3 follow-up); call `NSApp.activate(ignoringOtherApps: true)` inside `show(relativeTo:)` rather than relying on the caller (PR 7 review I1 follow-up).
- `Sources/RPPlayer/Shell/StatusItemController.swift` — drop the `NSApp.activate` call from the default `show` closure; the popover handles activation itself now.
- `Sources/RPPlayer/Shell/AppDelegate.swift` — build the real dependency graph: `JSONConfigStore`, `AppLogger`, `AnonymousCookieProvider`, `LiveRpApiClient`, `LibmpvPlayerEngine`, `LivePlaybackCoordinator`, `MiniPlayerViewModel`. Persist `selectedChannelId` to `ConfigStore` on changes. Cleanly call `coordinator.shutdown()` on `applicationWillTerminate`. (`KeychainCookieProvider` is wired in PR 9 alongside the rating row, since rating is the first feature that actually needs the auth cookie.)
- `Tests/RPPlayerTests/Shell/PopoverControllerTests.swift` — tests now construct the controller with an `AnyView(Text("probe"))` root and assert the panel hosts `NSHostingView<AnyView>`.
- `Tests/RPPlayerTests/Shell/AppDelegateTests.swift` — assert that `applicationDidFinishLaunching` produces a non-nil `statusItemController` and `viewModel`. The test injects an alternate `Bootstrap` so it never spins up a real `LibmpvPlayerEngine` (which would request audio devices). See Task 5.
- `CLAUDE.md` — flip PR 8 row to ✅, mark PR 9 as next, append the new test count, and record the PR-8-specific decisions described in Task 6.

**Deleted**

- `Sources/RPPlayer/Shell/AppShellPlaceholderView.swift` — replaced by `MiniPlayerView`.
- `Tests/RPPlayerTests/Shell/AppShellPlaceholderViewTests.swift` — covered tests for a deleted file.

---

## Conventions used by this PR

- **`ObservableObject` over `@Observable`:** the `@Observable` macro lands at macOS 14; we target 13. Use `final class: ObservableObject` with `@Published` for every state property the view reads.
- **`@MainActor` on the view model:** every property write happens on the main actor. The coordinator emits `NowPlaying` on its own actor; we hop to main inside the subscription `Task`.
- **Channel ID is `Int` internally:** the API returns `Channel.chan` as `String` (e.g. `"0"`), matching `GetBlock.chan`. Convert at the boundary with `Int(channel.chan)`. Reject non-integer channel IDs at startup with a logged warning; do not crash.
- **No coordinator subscription in `init`:** mirroring `LivePlaybackCoordinator`'s rule, the view model creates its subscription in `start()` (called from view `.task` modifier or AppDelegate). This avoids the Swift 6.2 detached-task-from-init pattern entirely.
- **No protocols for view layer:** the view model is concrete; PR 11 introduces protocols for AppContainer wiring. Per CLAUDE.md, no abstractions beyond current need.
- **Album art is a placeholder:** the view shows `Image(systemName: "music.quarternote.3")` inside a 200×200 frame. PR 9 introduces `AlbumArtCache` and replaces the placeholder.
- **Rating + Settings buttons are omitted, not stubbed:** the DESIGN spec lists both, but they are out of scope for PR 8. Stubbed UI would be misleading; omit and re-add in PR 9 / PR 10 with their respective concrete implementations.
- **Strict comment policy still applies:** single `//` lines, only when WHY is non-obvious.

### Verified upstream symbols (do NOT regress)

These signatures are the exact shipped surface as of `main` at PR 8 start. Use them verbatim; if any of these get refactored mid-PR, the plan must be updated, not worked around.

- `AppLogger.init(category: String, sink: RotatingFileSink? = nil, minimumLevel: Level = .info)` — subsystem is hard-coded inside the type.
- `ConfigPaths.configFile: URL` (singular) and `ConfigPaths.applicationSupportRoot: URL`.
- `JSONConfigStore.init(url: URL) throws`; `var settings: AppSettings { get async }`; `func update(_ mutate: @Sendable (inout AppSettings) -> Void) async throws`.
- `AnonymousCookieProvider()` zero-arg init; `currentCookie() async -> String?` returning `nil`.
- `LiveRpApiClient.init(baseURL: URL = .defaultBaseURL, session: URLSession = .shared, cookieProvider: any CookieProvider, logger: any Logging)`.
- `LibmpvPlayerEngine.init() throws` — no parameters.
- `LivePlaybackCoordinator.init(api: any RpApiClient, engine: any PlayerEngine, logger: any Logging, bitrate: Int)`.
- `PlayerEngine` protocol surface (used by the `NoopPlayerEngine` shim):
  ```swift
  public protocol PlayerEngine: Sendable {
      var events: AsyncStream<PlayerEvent> { get async }
      func play(url: URL) async throws
      func pause() async throws
      func resume() async throws
      func stop() async throws
      func seek(to seconds: Double) async throws
      func setHogMode(_ enabled: Bool) async throws
      func setOutputDevice(uid: String?) async throws
      func shutdown() async
  }
  ```
- `MockRpApiClient` is an `actor` exposing `listChannelsResponse: [Channel]`, `setBlockResponses(_:)`, `setInfoResponse(_:)`, `calls: [Call]`. PR 8 adds `listChannelsError: Error?` plus `setListChannelsResponse(_:)` and `setListChannelsError(_:)`.
- `MockPlaybackCoordinator` is an `actor` exposing `recordedCalls() -> [Call]`, `setNextError(_:)`, `setNowPlaying(_:)`, plus the protocol surface. The `Call` enum has cases `.play(channelId:)`, `.pause`, `.resume`, `.stop`, `.skipForward`, `.changeChannel(to:)`, `.shutdown`.

---

## Task 1: `MiniPlayerViewModel`

**Files:**
- Create: `Sources/RPPlayer/Shell/MiniPlayerViewModel.swift`
- Create: `Tests/RPPlayerTests/Shell/MiniPlayerViewModelTests.swift`

The view model owns the coordinator-subscription `Task` and `listChannels` prefetch. Tests use the existing `MockPlaybackCoordinator` and `MockRpApiClient` doubles (defined in `Tests/RPPlayerTests/Playback/`).

- [ ] **Step 1: Write the failing initial-state test**

`Tests/RPPlayerTests/Shell/MiniPlayerViewModelTests.swift`:

```swift
import XCTest
@testable import RPPlayer

@MainActor
final class MiniPlayerViewModelTests: XCTestCase {
    private var coordinator: MockPlaybackCoordinator!
    private var api: MockRpApiClient!
    private var sut: MiniPlayerViewModel!

    override func setUp() async throws {
        coordinator = MockPlaybackCoordinator()
        api = MockRpApiClient()
        sut = MiniPlayerViewModel(coordinator: coordinator, api: api, initialChannelId: 0)
    }

    override func tearDown() async throws {
        await sut.stop()
    }

    func testInitialStateBeforeStart() {
        XCTAssertNil(sut.nowPlaying)
        XCTAssertFalse(sut.isPlaying)
        XCTAssertEqual(sut.selectedChannelId, 0)
        XCTAssertTrue(sut.channels.isEmpty)
        XCTAssertNil(sut.errorMessage)
    }
}
```

- [ ] **Step 2: Run, expect compile failure**

Run: `swift test --filter RPPlayerTests.MiniPlayerViewModelTests`
Expected: `MiniPlayerViewModel` undefined.

- [ ] **Step 3: Implement the scaffold**

`Sources/RPPlayer/Shell/MiniPlayerViewModel.swift`:

```swift
import Combine
import Foundation

@MainActor
final class MiniPlayerViewModel: ObservableObject {
    @Published private(set) var nowPlaying: NowPlaying?
    @Published private(set) var isPlaying: Bool = false
    @Published private(set) var channels: [Channel] = []
    @Published private(set) var selectedChannelId: Int
    @Published private(set) var errorMessage: String?

    private let coordinator: any PlaybackCoordinator
    private let api: any RpApiClient
    private var subscriptionTask: Task<Void, Never>?

    init(
        coordinator: any PlaybackCoordinator,
        api: any RpApiClient,
        initialChannelId: Int
    ) {
        self.coordinator = coordinator
        self.api = api
        self.selectedChannelId = initialChannelId
    }
}
```

- [ ] **Step 4: Run, expect pass**

Run: `swift test --filter RPPlayerTests.MiniPlayerViewModelTests`
Expected: 1 test passes.

- [ ] **Step 5: Add the `start()` test**

Append to `MiniPlayerViewModelTests`:

```swift
    func testStartLoadsChannelsAndSubscribesToNowPlaying() async throws {
        let channel0 = Channel(chan: "0", title: "Main Mix", streamName: nil, bannerUrl: nil, slug: nil, image: nil)
        await api.setListChannelsResponse([channel0])

        await sut.start()

        XCTAssertEqual(sut.channels.map(\.chan), ["0"])
        XCTAssertEqual(sut.errorMessage, nil)
    }

    func testStartSurfacesListChannelsErrorAsErrorMessage() async throws {
        await api.setListChannelsError(RpApiError.network(URLError(.notConnectedToInternet)))

        await sut.start()

        XCTAssertNotNil(sut.errorMessage)
        XCTAssertTrue(sut.channels.isEmpty)
    }
```

- [ ] **Step 6: Run, expect failure**

Run: `swift test --filter RPPlayerTests.MiniPlayerViewModelTests`
Expected: compile errors — `start()` and the `MockRpApiClient.listChannelsResult` API may not exist yet. Inspect `Tests/RPPlayerTests/Playback/MockRpApiClient.swift` (added in PR 6) and use whatever programming surface it already provides for stubbing `listChannels()`. If the mock returns `[]` by default and has no `listChannelsResult`, extend it minimally to support a result-injecting property — guidance below in Step 7.

- [ ] **Step 7: Extend `MockRpApiClient`**

The PR-6 mock stores `listChannelsResponse: [Channel]` directly but does NOT support error injection for `listChannels()`. Add an optional `listChannelsError` plus matching setters. Edit `Tests/RPPlayerTests/Playback/MockRpApiClient.swift`:

Add the property:
```swift
var listChannelsError: Error?
```

Add the setters (the mock is an `actor`, so cross-actor mutations must go through methods):
```swift
func setListChannelsResponse(_ response: [Channel]) {
    self.listChannelsResponse = response
    self.listChannelsError = nil
}

func setListChannelsError(_ error: Error) {
    self.listChannelsError = error
}
```

Update `listChannels()` to throw when an error is set:
```swift
func listChannels() async throws -> [Channel] {
    calls.append(.listChannels)
    if let error = listChannelsError { throw error }
    return listChannelsResponse
}
```

Do **not** rename or remove any existing properties — `LivePlaybackCoordinatorTests` consumes `setBlockResponses(_:)`, `setInfoResponse(_:)`, etc.

- [ ] **Step 8: Implement `start()` and `stop()`**

```swift
    func start() async {
        do {
            self.channels = try await api.listChannels()
            self.errorMessage = nil
        } catch {
            self.errorMessage = "Failed to load channels: \(error.localizedDescription)"
        }

        // Snapshot whatever is currently playing before draining the stream.
        if let snapshot = await coordinator.nowPlaying {
            self.nowPlaying = snapshot
            self.isPlaying = true
        }

        let stream = await coordinator.nowPlayingUpdates
        subscriptionTask = Task { [weak self] in
            for await np in stream {
                guard let self else { return }
                await MainActor.run {
                    self.nowPlaying = np
                    self.isPlaying = true
                }
            }
        }
    }

    func stop() async {
        subscriptionTask?.cancel()
        subscriptionTask = nil
    }
```

- [ ] **Step 9: Run, expect pass**

Run: `swift test --filter RPPlayerTests.MiniPlayerViewModelTests`
Expected: 3 tests pass.

- [ ] **Step 10: Add play/pause/skip/changeChannel tests**

Append:

```swift
    func testTogglePlayPauseStartsPlaybackWhenNotPlaying() async throws {
        await sut.togglePlayPause()
        let calls = await coordinator.recordedCalls()
        XCTAssertEqual(calls, [.play(channelId: 0)])
        XCTAssertTrue(sut.isPlaying)
    }

    func testTogglePlayPausePausesWhenPlaying() async throws {
        sut.setIsPlayingForTesting(true)

        await sut.togglePlayPause()

        let calls = await coordinator.recordedCalls()
        XCTAssertEqual(calls, [.pause])
        XCTAssertFalse(sut.isPlaying)
    }

    func testSkipForwardCallsCoordinator() async throws {
        await sut.skipForward()
        let calls = await coordinator.recordedCalls()
        XCTAssertEqual(calls, [.skipForward])
    }

    func testSelectChannelChangesChannelOnCoordinator() async throws {
        await sut.selectChannel(2)
        let calls = await coordinator.recordedCalls()
        XCTAssertEqual(calls, [.changeChannel(to: 2)])
        XCTAssertEqual(sut.selectedChannelId, 2)
    }

    func testSelectChannelDoesNothingWhenIdUnchanged() async throws {
        await sut.selectChannel(0)
        let calls = await coordinator.recordedCalls()
        XCTAssertTrue(calls.isEmpty)
    }
```

- [ ] **Step 11: Run, expect failures**

Run: `swift test --filter RPPlayerTests.MiniPlayerViewModelTests`
Expected: compile errors for missing methods. The `setIsPlayingForTesting(_:)` method should be a `#if DEBUG`-gated test hook OR plain `internal` — go with internal since the package has no DEBUG/RELEASE split.

- [ ] **Step 12: Implement remaining methods**

Append to `MiniPlayerViewModel`:

```swift
    func togglePlayPause() async {
        if isPlaying {
            do {
                try await coordinator.pause()
                isPlaying = false
            } catch {
                errorMessage = "Pause failed: \(error.localizedDescription)"
            }
        } else {
            do {
                try await coordinator.play(channelId: selectedChannelId)
                isPlaying = true
            } catch {
                errorMessage = "Playback failed: \(error.localizedDescription)"
            }
        }
    }

    func skipForward() async {
        do {
            try await coordinator.skipForward()
        } catch {
            errorMessage = "Skip failed: \(error.localizedDescription)"
        }
    }

    func selectChannel(_ id: Int) async {
        guard id != selectedChannelId else { return }
        let previous = selectedChannelId
        selectedChannelId = id
        do {
            try await coordinator.changeChannel(to: id)
        } catch {
            selectedChannelId = previous
            errorMessage = "Channel change failed: \(error.localizedDescription)"
        }
    }

    func setIsPlayingForTesting(_ value: Bool) {
        isPlaying = value
    }
```

- [ ] **Step 13: Run, expect pass**

Run: `swift test --filter RPPlayerTests.MiniPlayerViewModelTests`
Expected: 7 tests pass.

- [ ] **Step 14: Add the persistence-closure test**

Append to `MiniPlayerViewModelTests`:

```swift
    func testSelectChannelInvokesPersistenceClosureOnSuccess() async throws {
        actor PersistenceCapture {
            var calls: [Int] = []
            func record(_ id: Int) { calls.append(id) }
        }
        let capture = PersistenceCapture()
        let coord = MockPlaybackCoordinator()
        let api = MockRpApiClient()
        let model = MiniPlayerViewModel(
            coordinator: coord,
            api: api,
            initialChannelId: 0,
            persistChannelId: { id in await capture.record(id) }
        )
        await model.selectChannel(2)
        let calls = await capture.calls
        XCTAssertEqual(calls, [2])
    }
```

- [ ] **Step 15: Run, expect compile failure**

Run: `swift test --filter RPPlayerTests.MiniPlayerViewModelTests`
Expected: compile failure — `init(coordinator:api:initialChannelId:persistChannelId:)` does not exist.

- [ ] **Step 16: Add the persistence parameter**

Modify `MiniPlayerViewModel`. Add:

```swift
    typealias PersistChannelId = @Sendable (Int) async -> Void
    private let persistChannelId: PersistChannelId
```

Replace the existing `init` so the persistence closure is the new optional parameter:

```swift
    init(
        coordinator: any PlaybackCoordinator,
        api: any RpApiClient,
        initialChannelId: Int,
        persistChannelId: @escaping PersistChannelId = { _ in }
    ) {
        self.coordinator = coordinator
        self.api = api
        self.selectedChannelId = initialChannelId
        self.persistChannelId = persistChannelId
    }
```

Update `selectChannel(_:)` to invoke it on success:

```swift
    func selectChannel(_ id: Int) async {
        guard id != selectedChannelId else { return }
        let previous = selectedChannelId
        selectedChannelId = id
        do {
            try await coordinator.changeChannel(to: id)
            await persistChannelId(id)
        } catch {
            selectedChannelId = previous
            errorMessage = "Channel change failed: \(error.localizedDescription)"
        }
    }
```

- [ ] **Step 17: Run, expect pass**

Run: `swift test --filter RPPlayerTests.MiniPlayerViewModelTests`
Expected: 8 tests pass.

- [ ] **Step 18: No `MockPlaybackCoordinator` change needed**

The PR 6 mock already records calls into a single `[Call]` array exposed via `recordedCalls()` and pattern-matched against the `Call` enum (`.play(channelId:)`, `.pause`, `.skipForward`, `.changeChannel(to:)`, `.shutdown`). The test code in Step 10 uses that surface — no edits to `MockPlaybackCoordinator.swift`.

- [ ] **Step 19: Commit**

```bash
git add Sources/RPPlayer/Shell/MiniPlayerViewModel.swift \
        Tests/RPPlayerTests/Shell/MiniPlayerViewModelTests.swift \
        Tests/RPPlayerTests/Playback/MockRpApiClient.swift
git commit -m "feat(pr08): MiniPlayerViewModel bridging coordinator to ObservableObject"
```

`MockPlaybackCoordinator.swift` is unchanged in this task. Stage `MockRpApiClient.swift` because Step 7 added `listChannelsError` + setters.

---

## Task 2: `MiniPlayerView`

**Files:**
- Create: `Sources/RPPlayer/Shell/MiniPlayerView.swift`
- Create: `Tests/RPPlayerTests/Shell/MiniPlayerViewTests.swift`

- [ ] **Step 1: Write failing render test**

`Tests/RPPlayerTests/Shell/MiniPlayerViewTests.swift`:

```swift
import AppKit
import SwiftUI
import XCTest
@testable import RPPlayer

@MainActor
final class MiniPlayerViewTests: XCTestCase {
    func testHostingControllerRendersWithoutCrash() {
        let coordinator = MockPlaybackCoordinator()
        let api = MockRpApiClient()
        let viewModel = MiniPlayerViewModel(coordinator: coordinator, api: api, initialChannelId: 0)
        let host = NSHostingController(rootView: MiniPlayerView(viewModel: viewModel))
        host.loadView()
        XCTAssertNotNil(host.view)
        XCTAssertGreaterThan(host.view.intrinsicContentSize.width, 0)
    }
}
```

- [ ] **Step 2: Run, expect failure**

Run: `swift test --filter RPPlayerTests.MiniPlayerViewTests`
Expected: `MiniPlayerView` undefined.

- [ ] **Step 3: Implement the view**

`Sources/RPPlayer/Shell/MiniPlayerView.swift`:

```swift
import SwiftUI

struct MiniPlayerView: View {
    @ObservedObject var viewModel: MiniPlayerViewModel

    var body: some View {
        VStack(spacing: 12) {
            artwork
            metadata
            transport
            channelPicker
            if let message = viewModel.errorMessage {
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .multilineTextAlignment(.center)
            }
        }
        .frame(width: 320, height: 420)
        .padding()
        .task { await viewModel.start() }
    }

    private var artwork: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 8)
                .fill(Color.secondary.opacity(0.15))
            Image(systemName: "music.quarternote.3")
                .font(.system(size: 48))
                .foregroundStyle(.secondary)
        }
        .frame(width: 200, height: 200)
    }

    private var metadata: some View {
        VStack(spacing: 4) {
            Text(viewModel.nowPlaying?.song.title ?? "—")
                .font(.headline)
                .lineLimit(1)
                .multilineTextAlignment(.center)
            Text(viewModel.nowPlaying.map { "\($0.song.artist) · \($0.song.album)" } ?? "Press play to start")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
    }

    private var transport: some View {
        HStack(spacing: 24) {
            Button {
                Task { await viewModel.togglePlayPause() }
            } label: {
                Image(systemName: viewModel.isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: 28))
            }
            .buttonStyle(.plain)
            .accessibilityLabel(viewModel.isPlaying ? "Pause" : "Play")

            Button {
                Task { await viewModel.skipForward() }
            } label: {
                Image(systemName: "forward.fill")
                    .font(.system(size: 24))
            }
            .buttonStyle(.plain)
            .disabled(!viewModel.isPlaying)
            .accessibilityLabel("Skip forward")
        }
    }

    private var channelPicker: some View {
        Picker("Channel", selection: Binding(
            get: { viewModel.selectedChannelId },
            set: { newId in Task { await viewModel.selectChannel(newId) } }
        )) {
            ForEach(viewModel.channels, id: \.chan) { channel in
                if let id = Int(channel.chan) {
                    Text(channel.title).tag(id)
                }
            }
        }
        .pickerStyle(.menu)
        .labelsHidden()
        .frame(maxWidth: .infinity)
    }
}
```

- [ ] **Step 4: Run, expect pass**

Run: `swift test --filter RPPlayerTests.MiniPlayerViewTests`
Expected: 1 test passes. The view model `start()` is invoked by the `.task` modifier when the host loads — that's fine; the `MockPlaybackCoordinator.nowPlayingUpdates` returns an empty stream by default and `MockRpApiClient.listChannels()` returns `[]` by default.

- [ ] **Step 5: Run the full suite**

Run: `swift test`
Expected: all previous tests + 8 new (7 model + 1 view) = 109. Confirm no regression.

- [ ] **Step 6: Commit**

```bash
git add Sources/RPPlayer/Shell/MiniPlayerView.swift \
        Tests/RPPlayerTests/Shell/MiniPlayerViewTests.swift
git commit -m "feat(pr08): MiniPlayerView SwiftUI rendering view-model state"
```

---

## Task 3: PR 7 follow-ups in the popover (Esc-to-dismiss, internal `NSApp.activate`)

**Files:**
- Modify: `Sources/RPPlayer/Shell/PopoverController.swift`
- Modify: `Sources/RPPlayer/Shell/StatusItemController.swift`
- Modify: `Tests/RPPlayerTests/Shell/StatusItemControllerTests.swift`

These two follow-ups land before swapping the hosted view in Task 4 because they only touch behavior that is already in place. Splitting them out keeps the diff readable.

- [ ] **Step 1: Read the current `PopoverController` and `StatusItemController`**

Confirm the current state matches what was merged in PR 7 (`git log -p Sources/RPPlayer/Shell/PopoverController.swift Sources/RPPlayer/Shell/StatusItemController.swift`).

- [ ] **Step 2: Update `PopoverController.show(relativeTo:)` and `installClickMonitor()`**

Edit `Sources/RPPlayer/Shell/PopoverController.swift` so that:
- `show(relativeTo:)` calls `NSApp.activate(ignoringOtherApps: true)` before `panel.orderFrontRegardless()`.
- `installClickMonitor()` also installs an `NSEvent.addLocalMonitorForEvents` for `.keyDown` events that closes on Esc (`keyCode == 53`) and otherwise returns the event unchanged. Both monitors live in two stored properties (`globalClickMonitor`, `localKeyMonitor`) and are torn down in `removeClickMonitor()` (rename to `removeMonitors()` for clarity).

The full updated file:

```swift
import AppKit
import SwiftUI

@MainActor
class PopoverController {
    static let contentSize = NSSize(width: 320, height: 420)

    let panel: NSPanel
    private var globalClickMonitor: Any?
    private var localKeyMonitor: Any?

    init(rootView: AnyView) {
        let hostingView = NSHostingView(rootView: rootView)
        hostingView.frame = NSRect(origin: .zero, size: Self.contentSize)

        let panel = NSPanel(
            contentRect: NSRect(origin: .zero, size: Self.contentSize),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isFloatingPanel = true
        panel.level = .statusBar
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.isReleasedWhenClosed = false
        panel.contentView = hostingView
        panel.contentView?.wantsLayer = true
        panel.contentView?.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
        panel.contentView?.layer?.cornerRadius = 10
        panel.contentView?.layer?.masksToBounds = true

        self.panel = panel
    }

    var isShown: Bool { panel.isVisible }

    func show(relativeTo anchor: NSView) {
        guard let buttonWindow = anchor.window else { return }
        let buttonRectInScreen = buttonWindow.convertToScreen(
            anchor.convert(anchor.bounds, to: nil)
        )
        // Activate so the panel comes to the foreground; otherwise the global
        // monitor never sees the user's outside clicks until they activate the app.
        NSApp.activate(ignoringOtherApps: true)
        let panelSize = panel.frame.size
        let origin = NSPoint(
            x: buttonRectInScreen.midX - panelSize.width / 2,
            y: buttonWindow.frame.minY - panelSize.height
        )
        panel.setFrameOrigin(origin)
        panel.orderFrontRegardless()
        installMonitors()
    }

    func close() {
        removeMonitors()
        panel.orderOut(nil)
    }

    private func installMonitors() {
        if globalClickMonitor == nil {
            globalClickMonitor = NSEvent.addGlobalMonitorForEvents(
                matching: [.leftMouseDown, .rightMouseDown]
            ) { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.close()
                }
            }
        }
        if localKeyMonitor == nil {
            localKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                if event.keyCode == 53 {
                    Task { @MainActor [weak self] in
                        self?.close()
                    }
                    return nil
                }
                return event
            }
        }
    }

    private func removeMonitors() {
        if let monitor = globalClickMonitor {
            NSEvent.removeMonitor(monitor)
            globalClickMonitor = nil
        }
        if let monitor = localKeyMonitor {
            NSEvent.removeMonitor(monitor)
            localKeyMonitor = nil
        }
    }
}
```

Note: the init now takes a generic SwiftUI root view via `AnyView`. This is a controlled use of type-erasure — the popover is the only entry point and it is hosted by AppKit, so structural typing is acceptable. Tests instantiate with whatever real view (or placeholder text view) they need.

- [ ] **Step 3: Update `StatusItemController` to drop the now-redundant activate**

Edit `Sources/RPPlayer/Shell/StatusItemController.swift`:

```swift
import AppKit

@MainActor
final class StatusItemController {
    let statusItem: NSStatusItem
    private let popover: PopoverController
    private let showHandler: (NSView) -> Void
    private let closeHandler: () -> Void

    init(
        statusBar: NSStatusBar = .system,
        popover: PopoverController,
        show: ((NSView) -> Void)? = nil,
        close: (() -> Void)? = nil
    ) {
        let item = statusBar.statusItem(withLength: NSStatusItem.variableLength)
        let image = NSImage(systemSymbolName: "music.note", accessibilityDescription: "RP Player")
        image?.isTemplate = true
        item.button?.image = image
        item.button?.toolTip = "RP Player"

        self.statusItem = item
        self.popover = popover
        self.showHandler = show ?? { anchor in popover.show(relativeTo: anchor) }
        self.closeHandler = close ?? { popover.close() }

        item.button?.target = self
        item.button?.action = #selector(buttonClicked(_:))
    }

    func toggle() {
        if popover.isShown {
            closeHandler()
        } else if let button = statusItem.button {
            showHandler(button)
        }
    }

    @objc private func buttonClicked(_ sender: NSStatusBarButton) {
        toggle()
    }
}
```

The only change vs PR 7 is the removal of the explicit `NSApp.activate(ignoringOtherApps: true)` call from the default `show` closure (and the comment that justified it).

- [ ] **Step 4: Build and run the existing tests**

Run: `swift build`
Expected: clean.

Run: `swift test --filter "RPPlayerTests.StatusItemControllerTests|RPPlayerTests.PopoverControllerTests"`
Expected: all 5 PR-7 shell tests still pass. The `PopoverControllerTests` will fail to compile because `PopoverController()` no longer takes zero args — that's Task 4's territory; defer the test fix to Task 4.

If the popover-controller tests fail to compile, that's expected and fine for this commit; do **not** edit them yet.

- [ ] **Step 5: Commit (skip the popover-controller tests for now)**

```bash
git add Sources/RPPlayer/Shell/PopoverController.swift \
        Sources/RPPlayer/Shell/StatusItemController.swift
git commit -m "fix(pr08): popover handles its own activation and Esc-to-dismiss"
```

---

## Task 4: Swap the hosted view + update `PopoverControllerTests`

**Files:**
- Modify: `Sources/RPPlayer/Shell/PopoverController.swift` — only if Task 3 left any rough edges
- Modify: `Tests/RPPlayerTests/Shell/PopoverControllerTests.swift`
- Delete: `Sources/RPPlayer/Shell/AppShellPlaceholderView.swift`
- Delete: `Tests/RPPlayerTests/Shell/AppShellPlaceholderViewTests.swift`

`PopoverController` now accepts an `AnyView` root from Task 3, so we don't need a second signature change. We just delete the placeholder and update the tests to assert that whatever root view we hand in is the one the panel hosts.

- [ ] **Step 1: Delete the placeholder source and tests**

```bash
git rm Sources/RPPlayer/Shell/AppShellPlaceholderView.swift \
       Tests/RPPlayerTests/Shell/AppShellPlaceholderViewTests.swift
```

- [ ] **Step 2: Rewrite `PopoverControllerTests` against the new init**

Replace `Tests/RPPlayerTests/Shell/PopoverControllerTests.swift`:

```swift
import AppKit
import SwiftUI
import XCTest
@testable import RPPlayer

@MainActor
final class PopoverControllerTests: XCTestCase {
    func testInitConfiguresBorderlessPanelWithProvidedRootView() {
        let controller = PopoverController(rootView: AnyView(Text("probe")))
        XCTAssertEqual(controller.panel.frame.size, NSSize(width: 320, height: 420))
        XCTAssertTrue(controller.panel.styleMask.contains(.borderless))
        XCTAssertTrue(controller.panel.styleMask.contains(.nonactivatingPanel))
        XCTAssertEqual(controller.panel.level, .statusBar)
        XCTAssertNotNil(controller.panel.contentView)
        XCTAssertTrue(controller.panel.contentView is NSHostingView<AnyView>)
    }

    func testIsShownReflectsPanelVisibility() {
        let controller = PopoverController(rootView: AnyView(Text("probe")))
        XCTAssertFalse(controller.isShown)
    }
}
```

The test no longer cares about which SwiftUI struct is hosted — only that the panel is configured correctly and hosts whatever `AnyView` the caller supplied. This is the right level of contract for `PopoverController`.

- [ ] **Step 3: Build and run**

Run: `swift build`
Expected: clean.

Run: `swift test --filter RPPlayerTests.PopoverControllerTests`
Expected: 2 tests pass.

Run: `swift test`
Expected: full suite passes; total now = previous + 2 model + 1 view + 0 popover (replaced) − 2 placeholder = 109 total.

If the count is off, the most likely culprit is `MockRpApiClient.listChannels()` defaulting differently than the test expects; see Task 1 Step 7.

- [ ] **Step 4: Commit**

```bash
git add Sources/RPPlayer/Shell/PopoverController.swift \
        Tests/RPPlayerTests/Shell/PopoverControllerTests.swift
git rm  Sources/RPPlayer/Shell/AppShellPlaceholderView.swift \
        Tests/RPPlayerTests/Shell/AppShellPlaceholderViewTests.swift
git commit -m "refactor(pr08): popover hosts caller-supplied root view; drop placeholder"
```

(`git rm` will only re-stage the deletion if it isn't already staged from Step 1; harmless if it is.)

---

## Task 5: Wire `AppDelegate` to the real coordinator graph

**Files:**
- Modify: `Sources/RPPlayer/Shell/AppDelegate.swift`
- Modify: `Tests/RPPlayerTests/Shell/AppDelegateTests.swift`

The `AppDelegate` now has to build the dependency graph. Inline construction is the right shape until PR 11; using a single `applicationDidFinishLaunching` keeps the graph easy to follow.

For tests: building a real `LibmpvPlayerEngine` in `swift test` would request CoreAudio devices and start a libmpv pump. We do not want that side-effect inside an `AppDelegateTests` invocation, so the delegate exposes a `bootstrap` closure that production sets to the real-graph builder and tests can override with a mock-graph builder.

- [ ] **Step 1: Write the failing test against an injectable bootstrap**

Replace `Tests/RPPlayerTests/Shell/AppDelegateTests.swift`:

```swift
import AppKit
import XCTest
@testable import RPPlayer

@MainActor
final class AppDelegateTests: XCTestCase {
    private var delegate: AppDelegate!

    override func setUp() async throws {
        delegate = AppDelegate(bootstrap: {
            let coordinator = MockPlaybackCoordinator()
            let api = MockRpApiClient()
            let viewModel = MiniPlayerViewModel(
                coordinator: coordinator,
                api: api,
                initialChannelId: 0
            )
            return AppDelegate.Bootstrap(
                viewModel: viewModel,
                coordinatorShutdown: { await coordinator.shutdown() }
            )
        })
    }

    override func tearDown() async throws {
        if let item = delegate?.statusItemController?.statusItem {
            NSStatusBar.system.removeStatusItem(item)
        }
        delegate = nil
    }

    func testApplicationDidFinishLaunchingCreatesStatusItemControllerAndViewModel() {
        XCTAssertNil(delegate.statusItemController)
        XCTAssertNil(delegate.viewModel)
        delegate.applicationDidFinishLaunching(Notification(name: NSApplication.didFinishLaunchingNotification))
        XCTAssertNotNil(delegate.statusItemController)
        XCTAssertNotNil(delegate.viewModel)
    }
}
```

`MockPlaybackCoordinator` already implements `shutdown()` (added in PR 6); confirm by inspecting `Tests/RPPlayerTests/Playback/MockPlaybackCoordinator.swift`.

- [ ] **Step 2: Run, expect failure**

Run: `swift test --filter RPPlayerTests.AppDelegateTests`
Expected: compile errors — `AppDelegate.init(bootstrap:)`, `AppDelegate.Bootstrap`, and `AppDelegate.viewModel` do not exist yet.

- [ ] **Step 3: Implement the new `AppDelegate`**

Replace `Sources/RPPlayer/Shell/AppDelegate.swift`:

```swift
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

    private static let realBootstrap: () -> Bootstrap = {
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
```

`NoopPlayerEngine` exists only to keep the menu-bar shell functional if `LibmpvPlayerEngine.init` throws. The shim's signatures match the verified `PlayerEngine` protocol surface (see "Verified upstream symbols" above) — use them verbatim.

- [ ] **Step 4: Build and run**

Run: `swift build`
Expected: clean.

Run: `swift test --filter RPPlayerTests.AppDelegateTests`
Expected: 1 test passes.

Run: `swift test`
Expected: full suite passes.

- [ ] **Step 5: Commit**

```bash
git add Sources/RPPlayer/Shell/AppDelegate.swift \
        Tests/RPPlayerTests/Shell/AppDelegateTests.swift
git commit -m "feat(pr08): wire AppDelegate to real coordinator/api/engine graph"
```

---

## Task 6: Polish + manual smoke + CLAUDE.md + merge

**Files:**
- Modify: `CLAUDE.md`
- (optional) any of the new files if review finds polish items

- [ ] **Step 1: Comment audit**

Review every `//` line introduced in PR 8 (in `MiniPlayerViewModel`, `MiniPlayerView`, `PopoverController`, `AppDelegate`). Each must explain a non-obvious WHY (not the WHAT). Strip any that don't pass the bar. Expected to keep:
- The `// Activate so the panel comes to the foreground; otherwise the global monitor never sees the user's outside clicks` comment in `PopoverController.show(relativeTo:)`.
- The `// initialChannelId comes from ConfigStore in the real bootstrap; tests can pass whatever they like through the override.` comment in `AppDelegate.applicationDidFinishLaunching`.
- The `// Block the terminate path on a clean shutdown of the coordinator — libmpv must release the audio device before we exit.` comment in `AppDelegate.applicationWillTerminate`.

- [ ] **Step 2: Build clean**

Run: `swift build`
Expected: clean, no new warnings vs. pre-PR-8.

- [ ] **Step 3: Run the full suite**

Run: `swift test`
Expected: every test passes. Capture the new total. Expected delta: +9 (8 model + 1 view) − 2 placeholder = +7 net, so 101 + 7 = 108. If the actual count differs, reconcile — adjust the CLAUDE.md entry to match reality.

- [ ] **Step 4: Manual smoke**

Run: `swift run RPPlayer`

Confirm:
- The menu-bar icon appears.
- Click → popover opens flush against the menu bar with rounded corners.
- The popover shows "—" / "Press play to start" until the user clicks Play.
- Click Play → the popover updates to show real song metadata (title, artist · album).
- Click Skip → the next song appears within a second or two.
- Use the channel picker → switches channel; the title row updates to a song from the new channel.
- Click outside → popover dismisses.
- Press Esc while the popover is open → popover dismisses.
- Quit with `Ctrl-C` (no `Cmd-Q` until PR 11). Confirm in `Console.app` filtered on `RPPlayer` that the coordinator's `shutdown` log line fires.

If any smoke point fails, STOP, report `BLOCKED — smoke step <N> failed`, and do not continue.

- [ ] **Step 5: Update `CLAUDE.md`**

In the PR table, change PR 8 to ✅ merged and PR 9 to **next** ⬜:

```markdown
| 8 | merged to main | ✅ | MiniPlayerView (SwiftUI) + AppDelegate wiring |
| 9 | **next** | ⬜ | NotificationCenterWrapper + AlbumArtCache |
```

Replace the "PR 7 shipped scope" paragraph with a "PR 8 shipped scope" paragraph mirroring its shape.

Append to "Test counts by PR":

```markdown
- After PR 8: <new total> tests
```

Append to "Key technical decisions":

```markdown
- `MiniPlayerViewModel` is `@MainActor final class: ObservableObject`, not an `@Observable` class — `@Observable` requires macOS 14 and we target macOS 13. Re-evaluate when the project bumps the deployment target.
- The view model's `start()` method (not `init`) is where the coordinator subscription `Task` is spawned. Mirrors `LivePlaybackCoordinator`'s rule: do not capture `self` into a `Task` from a non-isolated init under Swift 6.2. The view's `.task` modifier calls `start()` on first appear; `stop()` cancels the task on disappear / `tearDown`.
- `AppDelegate.applicationWillTerminate` blocks the terminate path on `coordinator.shutdown()` via a `DispatchGroup.wait(timeout: 2.0)`. libmpv must release the audio device before the process exits, or hog mode can leave the device unusable to other apps for several seconds. The 2 s cap matches the engine's pump shutdown budget.
- `AppDelegate.realBootstrap` is the temporary composition root for PR 8. PR 11 (`AppContainer`) refactors it into a dedicated type with proper protocol-based DI. The `Bootstrap` struct + closure-based override exists so `AppDelegateTests` can avoid spinning up a real `LibmpvPlayerEngine`.
- `PopoverController(rootView:)` takes an `AnyView` rather than a generic `<RootView: View>` so the controller can be constructed before the view model exists (e.g. from `AppDelegate.applicationDidFinishLaunching`) without the caller having to pin a concrete generic at every callsite. The type-erasure cost is negligible — the popover is the only construction site.
- The popover installs both an `NSEvent.addGlobalMonitorForEvents` (outside-click dismissal) and `NSEvent.addLocalMonitorForEvents` (Esc-to-dismiss) on `show(relativeTo:)`. Both are torn down in `close()`. Esc handling is required because `.nonactivatingPanel` panels cannot become key, so SwiftUI's built-in `.dismiss` does not fire.
- `MiniPlayerViewModel.persistChannelId` is a `@Sendable` async closure injected at init. Production wires it to `await JSONConfigStore.update { ... }`; tests pass an actor-backed capture. The closure-of-async pattern keeps the view model from depending on the `ConfigStore` protocol directly — PR 11 will revisit this when `AppContainer` lands.
```

- [ ] **Step 6: Commit `CLAUDE.md`**

```bash
git add CLAUDE.md
git commit -m "docs(pr08): record MiniPlayerView decisions and post-PR8 test count"
```

- [ ] **Step 7: Fast-forward merge to `main`**

From `/Users/gergely/git/rp-player`:

```bash
cd /Users/gergely/git/rp-player
git merge --ff-only <PR-8-branch>
git rev-list --count main..HEAD   # must print 0
```

If any non-PR-8 changes are present in the primary worktree, STOP and ask the user how to handle.

---

## Self-review checklist

- **Spec coverage:** every PR 8 row item from `CLAUDE.md` ("MiniPlayerView (SwiftUI)") is implemented or explicitly deferred. Album art and rating + settings link are deferred to PR 9 / PR 10 with rationale in CLAUDE.md.
- **PR 7 follow-ups:** I1 (move `NSApp.activate`) and M3 (Esc-to-dismiss) are addressed. M5 (dynamic Light/Dark color) is **NOT** addressed in this PR — log a TODO in CLAUDE.md and surface it in the PR 9 plan.
- **Comment policy:** every `//` line explains a non-obvious WHY.
- **Test count math:** previous = 101, expected new = 108 (+8 model + 1 view + 0 view-test additions − 2 placeholder), adjust to match reality.
- **No new abstractions in the view layer:** MiniPlayerView reads the concrete `MiniPlayerViewModel`. PR 11 will introduce protocols if mockable wiring becomes necessary.
- **No regression:** `swift build` clean, `swift test` 100% pass, manual smoke green.

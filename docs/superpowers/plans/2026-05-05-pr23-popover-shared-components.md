# PR 23: Popover shared components + ambient parity for past-song popover

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Unify the past-song notification popover and the main popover so they render with identical chrome, identical art / title styling, and the same opt-in ambient gradient background — by extracting shared SwiftUI components and a shared panel base, and by wiring `paletteExtractor` + `configStore` into `PastSongViewModel`.

**Architecture:** Pull three duplicated UI fragments out of `MiniPlayerView` and `PastSongView` into a new `Sources/RPPlayer/Shell/Components/` directory: `PopoverAlbumArt` (`Group`-style image), `SongTitleRow` (title/artist/album + RatingMenu), `AmbientGradientBackground` (the 2-stop gradient). Replace `PastSongPopoverController` with a shared `BorderlessPopoverPanel` base used by both `PopoverController` and the past-song flow (or fold past-song presentation into `PopoverController` directly with an `AnyView` swap path — Task 5 picks). Add ambient palette wiring + sticky-color rules to `PastSongViewModel` mirroring `MiniPlayerViewModel`.

**Tech Stack:** Swift 6.2, SwiftUI, AppKit (NSPanel + NSHostingView), `swift test` (XCTest).

---

## File Structure

**Create:**
- `Sources/RPPlayer/Shell/Components/PopoverAlbumArt.swift` — shared 342×342 album-art view with placeholder fallback
- `Sources/RPPlayer/Shell/Components/SongTitleRow.swift` — shared title/artist/album block + `RatingMenu` on the right; takes optional album, signed-in flag, current rating, on-rate closure
- `Sources/RPPlayer/Shell/Components/AmbientGradientBackground.swift` — shared 2-stop `LinearGradient` background view + `.animation` on a `Color?` binding
- `Tests/RPPlayerTests/Shell/Components/SongTitleRowTests.swift` — host-controller smoke tests
- `Tests/RPPlayerTests/Shell/Components/AmbientGradientBackgroundTests.swift` — host-controller smoke tests

**Modify:**
- `Sources/RPPlayer/Shell/MiniPlayerView.swift` — replace `albumArt`, `titleRow`, `ambientBackground` private vars with the shared components
- `Sources/RPPlayer/Shell/PastSongView.swift` — same; plus add ambient gradient background + animation
- `Sources/RPPlayer/Shell/PastSongViewModel.swift` — add `configStore` + `paletteExtractor` + `ambientTopColor` + ambient subscription mirroring `MiniPlayerViewModel`
- `Sources/RPPlayer/Shell/PastSongPopoverController.swift` — delete (replaced by shared base) OR reduce to a thin subclass that hosts `PastSongView` (Task 5 picks)
- `Sources/RPPlayer/App/AppContainer.swift` — pass `configStore` + `AmbientPaletteExtractor()` into `PastSongViewModel` construction (currently happens in `AppDelegate` for the past-song flow)
- `Sources/RPPlayer/Shell/AppDelegate.swift` — update `PastSongViewModel` constructor call site with the two new args
- `Tests/RPPlayerTests/Shell/PastSongViewModelTests.swift` — update existing constructor calls; add ambient extraction test
- `Tests/RPPlayerTests/Shell/PastSongViewTests.swift` — update constructor call
- `Tests/RPPlayerTests/Shell/PastSongPopoverControllerTests.swift` — update constructor call (and potentially file deletion if Task 5 folds it)
- `Tests/RPPlayerTests/Notifications/NotificationClickRouterTests.swift` — none if router doesn't construct `PastSongViewModel`; verify

**Files that change together (rationale):** the shared UI components live with the views that use them. Tests for shared components live in `Tests/.../Shell/Components/` next to source.

---

### Task 1: Extract `PopoverAlbumArt` shared component

**Files:**
- Create: `Sources/RPPlayer/Shell/Components/PopoverAlbumArt.swift`
- Modify: `Sources/RPPlayer/Shell/MiniPlayerView.swift`
- Modify: `Sources/RPPlayer/Shell/PastSongView.swift`

- [ ] **Step 1: Write the new shared view file**

Path: `Sources/RPPlayer/Shell/Components/PopoverAlbumArt.swift`

```swift
import AppKit
import SwiftUI

struct PopoverAlbumArt: View {
    let image: NSImage?
    var size: CGFloat = 342

    var body: some View {
        Group {
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFill()
                    .frame(width: size, height: size)
                    .clipped()
            } else {
                Image(systemName: "music.note")
                    .resizable()
                    .scaledToFit()
                    .padding(80)
                    .foregroundStyle(.secondary)
                    .frame(width: size, height: size)
                    .background(Color(nsColor: .controlBackgroundColor))
            }
        }
    }
}
```

- [ ] **Step 2: Replace `MiniPlayerView.albumArt` with the shared component**

In `Sources/RPPlayer/Shell/MiniPlayerView.swift`, replace the private `albumArt` computed var (lines 34-52) with a call site change in `body` (line 19):

```swift
PopoverAlbumArt(image: viewModel.currentArt)
```

Delete the `albumArt` private var entirely.

- [ ] **Step 3: Replace `PastSongView.albumArt` with the shared component**

In `Sources/RPPlayer/Shell/PastSongView.swift`, replace `albumArt` (lines 19-37) with the same call in `body`:

```swift
PopoverAlbumArt(image: viewModel.currentArt)
```

Delete the `albumArt` private var entirely.

- [ ] **Step 4: Build**

Run: `swift build`
Expected: build succeeds, no warnings related to the changed files.

- [ ] **Step 5: Run all tests**

Run: `swift test`
Expected: 324 tests pass (no behavioral change, only refactor).

- [ ] **Step 6: Commit**

```bash
git add Sources/RPPlayer/Shell/Components/PopoverAlbumArt.swift Sources/RPPlayer/Shell/MiniPlayerView.swift Sources/RPPlayer/Shell/PastSongView.swift
git commit -m "refactor(shell): extract PopoverAlbumArt shared component"
```

---

### Task 2: Extract `SongTitleRow` shared component

**Files:**
- Create: `Sources/RPPlayer/Shell/Components/SongTitleRow.swift`
- Create: `Tests/RPPlayerTests/Shell/Components/SongTitleRowTests.swift`
- Modify: `Sources/RPPlayer/Shell/MiniPlayerView.swift`
- Modify: `Sources/RPPlayer/Shell/PastSongView.swift`

The current MiniPlayer uses `.title3` for title, `.subheadline` `.primary` for artist, `.caption` `.primary` for album. PastSong uses `.headline` / `.subheadline` `.secondary` / `.caption` `.tertiary`. The user's stated requirement is "exact same thing, without the active player elements" → adopt MiniPlayer's typography in the shared component.

- [ ] **Step 1: Write the failing test**

Path: `Tests/RPPlayerTests/Shell/Components/SongTitleRowTests.swift`

```swift
import AppKit
import SwiftUI
import XCTest
@testable import RPPlayer

@MainActor
final class SongTitleRowTests: XCTestCase {
    func testHostingControllerRendersWithoutCrash() {
        let view = SongTitleRow(
            title: "Title",
            artist: "Artist",
            album: "Album",
            currentRating: 7,
            isSignedIn: true,
            onRate: { _ in }
        )
        let host = NSHostingController(rootView: view)
        host.loadView()
        XCTAssertNotNil(host.view)
    }

    func testRendersWithNilAlbumAndSignedOut() {
        let view = SongTitleRow(
            title: "T",
            artist: "A",
            album: nil,
            currentRating: nil,
            isSignedIn: false,
            onRate: { _ in }
        )
        let host = NSHostingController(rootView: view)
        host.loadView()
        XCTAssertNotNil(host.view)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter SongTitleRowTests`
Expected: FAIL with "cannot find 'SongTitleRow' in scope".

- [ ] **Step 3: Write the shared view**

Path: `Sources/RPPlayer/Shell/Components/SongTitleRow.swift`

```swift
import SwiftUI

struct SongTitleRow: View {
    let title: String
    let artist: String
    let album: String?
    let currentRating: Int?
    let isSignedIn: Bool
    let onRate: (Int) -> Void

    var body: some View {
        HStack(alignment: .center, spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.title3)
                    .lineLimit(1)
                Text(artist)
                    .font(.subheadline)
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                if let album, !album.isEmpty {
                    Text(album)
                        .font(.caption)
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            RatingMenu(
                currentRating: currentRating,
                isSignedIn: isSignedIn,
                onRate: onRate
            )
        }
        .frame(width: 318)
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test --filter SongTitleRowTests`
Expected: PASS (2 tests).

- [ ] **Step 5: Replace `MiniPlayerView.titleRow`**

In `Sources/RPPlayer/Shell/MiniPlayerView.swift`, replace `titleRow` (lines 65-94) usage in body (line 21) with:

```swift
SongTitleRow(
    title: viewModel.nowPlaying?.song.title ?? "—",
    artist: viewModel.nowPlaying?.song.artist ?? "",
    album: viewModel.nowPlaying?.song.album,
    currentRating: viewModel.currentRating,
    isSignedIn: viewModel.isSignedIn,
    onRate: { value in Task { await viewModel.rate(value) } }
)
```

Delete the `titleRow` private var.

- [ ] **Step 6: Replace `PastSongView.titleRow`**

In `Sources/RPPlayer/Shell/PastSongView.swift`, replace `titleRow` (lines 39-66) usage in body (line 11) with:

```swift
SongTitleRow(
    title: viewModel.song.title,
    artist: viewModel.song.artist,
    album: viewModel.song.album,
    currentRating: viewModel.currentRating,
    isSignedIn: viewModel.isSignedIn,
    onRate: { value in Task { await viewModel.rate(value) } }
)
```

Delete the `titleRow` private var.

- [ ] **Step 7: Run full test suite**

Run: `swift test`
Expected: 326 tests pass (324 + 2 new).

- [ ] **Step 8: Commit**

```bash
git add Sources/RPPlayer/Shell/Components/SongTitleRow.swift Tests/RPPlayerTests/Shell/Components/SongTitleRowTests.swift Sources/RPPlayer/Shell/MiniPlayerView.swift Sources/RPPlayer/Shell/PastSongView.swift
git commit -m "refactor(shell): extract SongTitleRow shared component"
```

---

### Task 3: Extract `AmbientGradientBackground` shared component

**Files:**
- Create: `Sources/RPPlayer/Shell/Components/AmbientGradientBackground.swift`
- Create: `Tests/RPPlayerTests/Shell/Components/AmbientGradientBackgroundTests.swift`
- Modify: `Sources/RPPlayer/Shell/MiniPlayerView.swift`

- [ ] **Step 1: Write the failing test**

Path: `Tests/RPPlayerTests/Shell/Components/AmbientGradientBackgroundTests.swift`

```swift
import AppKit
import SwiftUI
import XCTest
@testable import RPPlayer

@MainActor
final class AmbientGradientBackgroundTests: XCTestCase {
    func testRendersWithNilColor() {
        let view = AmbientGradientBackground(topColor: nil)
        let host = NSHostingController(rootView: view.frame(width: 100, height: 100))
        host.loadView()
        XCTAssertNotNil(host.view)
    }

    func testRendersWithColor() {
        let view = AmbientGradientBackground(topColor: Color.red)
        let host = NSHostingController(rootView: view.frame(width: 100, height: 100))
        host.loadView()
        XCTAssertNotNil(host.view)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter AmbientGradientBackgroundTests`
Expected: FAIL with "cannot find 'AmbientGradientBackground' in scope".

- [ ] **Step 3: Write the shared view**

Path: `Sources/RPPlayer/Shell/Components/AmbientGradientBackground.swift`

```swift
import SwiftUI

struct AmbientGradientBackground: View {
    let topColor: Color?

    var body: some View {
        LinearGradient(
            colors: [
                topColor ?? Color(nsColor: .windowBackgroundColor),
                (topColor ?? Color(nsColor: .windowBackgroundColor)).opacity(0.4)
            ],
            startPoint: .top,
            endPoint: .bottom
        )
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test --filter AmbientGradientBackgroundTests`
Expected: PASS (2 tests).

- [ ] **Step 5: Use shared component in `MiniPlayerView`**

In `Sources/RPPlayer/Shell/MiniPlayerView.swift`, replace `.background(ambientBackground)` (line 29) with:

```swift
.background(AmbientGradientBackground(topColor: viewModel.ambientTopColor))
```

Delete the `ambientBackground` private var (lines 54-63). Keep the `.animation(.easeInOut(duration: 0.4), value: viewModel.ambientTopColor)` modifier on the body — it stays at the call site.

- [ ] **Step 6: Run full test suite**

Run: `swift test`
Expected: 328 tests pass.

- [ ] **Step 7: Commit**

```bash
git add Sources/RPPlayer/Shell/Components/AmbientGradientBackground.swift Tests/RPPlayerTests/Shell/Components/AmbientGradientBackgroundTests.swift Sources/RPPlayer/Shell/MiniPlayerView.swift
git commit -m "refactor(shell): extract AmbientGradientBackground shared component"
```

---

### Task 4: Wire ambient palette + configStore into `PastSongViewModel`

The past-song popover must respect `AppSettings.ambientBackgroundEnabled`, sample the album-art bottom edge via `AmbientPaletteExtracting`, and clear the color on promo songs (`songId == "0"`) — same rules as `MiniPlayerViewModel`. Errors stream is **not** subscribed: past-song view has no live engine; mid-track engine errors should not affect a static historical song view.

**Files:**
- Modify: `Sources/RPPlayer/Shell/PastSongViewModel.swift`
- Modify: `Tests/RPPlayerTests/Shell/PastSongViewModelTests.swift`

- [ ] **Step 1: Write the failing test**

In `Tests/RPPlayerTests/Shell/PastSongViewModelTests.swift`, add:

```swift
func testStartExtractsAmbientColorWhenEnabledAndCoverPresent() async {
    let cache = StubAlbumArtCache()
    cache.imageByPath["covers/l/x.jpg"] = NSImage(size: NSSize(width: 16, height: 16))
    var settings = AppSettings.default
    settings.ambientBackgroundEnabled = true
    let store = StubConfigStore(initial: settings)
    let extractor = StubAmbientPaletteExtractor(
        nextResult: ExtractedColor(red: 0.5, green: 0.25, blue: 0.75)
    )
    let sut = PastSongViewModel(
        song: makeSong(cover: "covers/l/x.jpg"),
        albumArtCache: cache,
        auth: StubKeychainAuth(),
        api: MockRpApiClient(),
        configStore: store,
        paletteExtractor: extractor
    )
    await sut.start()
    // Yield to let the palette task run.
    for _ in 0..<5 { await Task.yield() }
    XCTAssertNotNil(sut.ambientTopColor)
}

func testStartSkipsAmbientExtractionWhenDisabled() async {
    let cache = StubAlbumArtCache()
    cache.imageByPath["covers/l/x.jpg"] = NSImage(size: NSSize(width: 16, height: 16))
    let store = StubConfigStore(initial: .default) // ambient disabled by default
    let extractor = StubAmbientPaletteExtractor(
        nextResult: ExtractedColor(red: 0.5, green: 0.25, blue: 0.75)
    )
    let sut = PastSongViewModel(
        song: makeSong(cover: "covers/l/x.jpg"),
        albumArtCache: cache,
        auth: StubKeychainAuth(),
        api: MockRpApiClient(),
        configStore: store,
        paletteExtractor: extractor
    )
    await sut.start()
    for _ in 0..<5 { await Task.yield() }
    XCTAssertNil(sut.ambientTopColor)
    XCTAssertTrue(extractor.calls.isEmpty)
}

func testStartClearsAmbientColorForPromoSong() async {
    let cache = StubAlbumArtCache()
    cache.imageByPath["covers/l/promo.jpg"] = NSImage(size: NSSize(width: 16, height: 16))
    var settings = AppSettings.default
    settings.ambientBackgroundEnabled = true
    let store = StubConfigStore(initial: settings)
    let extractor = StubAmbientPaletteExtractor(
        nextResult: ExtractedColor(red: 1, green: 1, blue: 1)
    )
    var promo = makeSong(cover: "covers/l/promo.jpg")
    promo = PlayListSong(
        songId: "0", artist: promo.artist, title: promo.title, album: promo.album,
        duration: promo.duration, event: promo.event, schedTime: promo.schedTime,
        chan: promo.chan, year: promo.year, asin: promo.asin, rating: promo.rating,
        userRating: promo.userRating, cover: promo.cover, elapsed: promo.elapsed,
        slideshow: promo.slideshow, type: "P", sliceNum: promo.sliceNum
    )
    let sut = PastSongViewModel(
        song: promo,
        albumArtCache: cache,
        auth: StubKeychainAuth(),
        api: MockRpApiClient(),
        configStore: store,
        paletteExtractor: extractor
    )
    await sut.start()
    for _ in 0..<5 { await Task.yield() }
    XCTAssertNil(sut.ambientTopColor)
}
```

Update the existing 5 tests to pass the two new constructor args. Default values: `configStore: StubConfigStore(initial: .default), paletteExtractor: StubAmbientPaletteExtractor()`.

- [ ] **Step 2: Run test to verify failure**

Run: `swift test --filter PastSongViewModelTests`
Expected: FAIL — extra params on initializer; new tests reference `ambientTopColor` which doesn't exist.

- [ ] **Step 3: Update `PastSongViewModel`**

Replace `Sources/RPPlayer/Shell/PastSongViewModel.swift` body. Note: `configStore` is `any ConfigStore` (an actor protocol), so reading `settings.ambientBackgroundEnabled` is `await` like in `MiniPlayerViewModel.start()`.

```swift
import AppKit
import Foundation
import SwiftUI

@MainActor
public final class PastSongViewModel: ObservableObject {
    public let song: PlayListSong
    @Published public private(set) var currentArt: NSImage?
    @Published public private(set) var currentRating: Int?
    @Published public private(set) var isSignedIn: Bool
    @Published public private(set) var ambientTopColor: Color?

    private let albumArtCache: any AlbumArtCache
    private let auth: any KeychainAuth
    private let api: any RpApiClient
    private let configStore: any ConfigStore
    private let paletteExtractor: any AmbientPaletteExtracting
    private var ambientEnabled: Bool = false
    private var paletteTask: Task<Void, Never>?
    private var settingsSubscriptionTask: Task<Void, Never>?

    public init(
        song: PlayListSong,
        albumArtCache: any AlbumArtCache,
        auth: any KeychainAuth,
        api: any RpApiClient,
        configStore: any ConfigStore,
        paletteExtractor: any AmbientPaletteExtracting
    ) {
        self.song = song
        self.albumArtCache = albumArtCache
        self.auth = auth
        self.api = api
        self.configStore = configStore
        self.paletteExtractor = paletteExtractor
        self.currentRating = Self.parseRating(song.userRating)
        self.isSignedIn = auth.isLoggedIn
    }

    public func start() async {
        isSignedIn = auth.isLoggedIn
        currentRating = Self.parseRating(song.userRating)
        ambientEnabled = await configStore.settings.ambientBackgroundEnabled

        // Subscribe to changes so toggling ambient mid-view updates color.
        let stream = await configStore.changes
        settingsSubscriptionTask?.cancel()
        settingsSubscriptionTask = Task { [weak self] in
            for await snapshot in stream {
                guard let self else { return }
                let was = self.ambientEnabled
                self.ambientEnabled = snapshot.ambientBackgroundEnabled
                if was, !snapshot.ambientBackgroundEnabled {
                    self.ambientTopColor = nil
                } else if !was, snapshot.ambientBackgroundEnabled, let image = self.currentArt {
                    self.extractPalette(from: image)
                }
            }
        }

        guard let cover = song.cover else { return }
        let image = await albumArtCache.image(for: cover)
        currentArt = image
        guard song.songId != "0" else {
            ambientTopColor = nil
            return
        }
        if let image, ambientEnabled {
            extractPalette(from: image)
        }
    }

    public func rate(_ value: Int) async {
        guard let id = Int(song.songId) else { return }
        do {
            _ = try await api.rate(songId: id, rating: value)
            currentRating = value
        } catch {
            // Leave currentRating unchanged. No error UI in this minimal view.
        }
    }

    private func extractPalette(from image: NSImage) {
        paletteTask?.cancel()
        paletteTask = Task { [weak self, paletteExtractor] in
            let extracted = await paletteExtractor.extractBottomEdgeColor(from: image)
            guard let self else { return }
            await MainActor.run {
                self.ambientTopColor = extracted?.swiftUIColor
            }
        }
    }

    private static func parseRating(_ raw: String?) -> Int? {
        guard let raw, let value = Int(raw), (1...10).contains(value) else { return nil }
        return value
    }
}
```

- [ ] **Step 4: Run test to verify pass**

Run: `swift test --filter PastSongViewModelTests`
Expected: PASS — 8 tests (5 updated + 3 new).

- [ ] **Step 5: Build full project (compile-error catch for downstream call sites)**

Run: `swift build`
Expected: errors at `AppDelegate.swift:99` (PastSongViewModel call site) and `PastSongPopoverControllerTests.swift:18` and `PastSongViewTests.swift:15` — those reference the old 4-arg init.

- [ ] **Step 6: Update `AppDelegate.swift` call site**

In `Sources/RPPlayer/Shell/AppDelegate.swift`, the `pastSongPresenter` closure (lines 96-106) constructs `PastSongViewModel`. The closure already has access to `container`. Update to:

```swift
pastSongPresenter: { [weak statusItemController, container] song in
    statusItemController?.closeIfShown()
    guard let anchor = statusItemController?.statusItem.button else { return }
    let viewModel = PastSongViewModel(
        song: song,
        albumArtCache: container.albumArtCache,
        auth: container.keychainAuth,
        api: container.api,
        configStore: container.configStore,
        paletteExtractor: AmbientPaletteExtractor()
    )
    container.pastSongPopoverController.present(viewModel: viewModel, relativeTo: anchor)
}
```

- [ ] **Step 7: Update `PastSongPopoverControllerTests.swift` call site**

Add `configStore: StubConfigStore(initial: .default), paletteExtractor: StubAmbientPaletteExtractor()` to the `PastSongViewModel` init at line 18.

- [ ] **Step 8: Update `PastSongViewTests.swift` call site**

Add the same two args to the `PastSongViewModel` init at line 15.

- [ ] **Step 9: Run full test suite**

Run: `swift test`
Expected: 331 tests pass (328 + 3 new).

- [ ] **Step 10: Commit**

```bash
git add Sources/RPPlayer/Shell/PastSongViewModel.swift Sources/RPPlayer/Shell/AppDelegate.swift Tests/RPPlayerTests/Shell/PastSongViewModelTests.swift Tests/RPPlayerTests/Shell/PastSongPopoverControllerTests.swift Tests/RPPlayerTests/Shell/PastSongViewTests.swift
git commit -m "feat(shell): ambient gradient parity for past-song popover"
```

---

### Task 5: Apply ambient gradient to `PastSongView` body

`PastSongViewModel` now publishes `ambientTopColor` — but `PastSongView` doesn't render it. Hook the shared `AmbientGradientBackground` + animation modifier.

**Files:**
- Modify: `Sources/RPPlayer/Shell/PastSongView.swift`

- [ ] **Step 1: Update `PastSongView.body`**

After Tasks 1-3, the file is short. Replace its body so it matches MiniPlayer's structure (frame width 342, ambient background, 0.4s ease-in-out animation, `.task { await start() }`):

```swift
import AppKit
import SwiftUI

struct PastSongView: View {
    @ObservedObject var viewModel: PastSongViewModel

    var body: some View {
        VStack(spacing: 0) {
            PopoverAlbumArt(image: viewModel.currentArt)
            VStack(spacing: 12) {
                SongTitleRow(
                    title: viewModel.song.title,
                    artist: viewModel.song.artist,
                    album: viewModel.song.album,
                    currentRating: viewModel.currentRating,
                    isSignedIn: viewModel.isSignedIn,
                    onRate: { value in Task { await viewModel.rate(value) } }
                )
            }
            .padding(12)
        }
        .frame(width: 342)
        .background(AmbientGradientBackground(topColor: viewModel.ambientTopColor))
        .animation(.easeInOut(duration: 0.4), value: viewModel.ambientTopColor)
        .task { await viewModel.start() }
    }
}
```

- [ ] **Step 2: Run all tests**

Run: `swift test`
Expected: 331 tests pass — `PastSongViewTests.testHostingControllerRendersWithoutCrash` still hosts cleanly.

- [ ] **Step 3: Commit**

```bash
git add Sources/RPPlayer/Shell/PastSongView.swift
git commit -m "feat(shell): paint ambient gradient on past-song popover"
```

---

### Task 6: Match panel chrome — adjust past-song popover content size

`PopoverController.contentSize` is `320×540`. `PastSongPopoverController.contentSize` is `342×540`. The 22-pt width gap is because `MiniPlayerView` was `342` wide (album art is 342 square) but the *panel* was `320` — the system shadow and corner clip happen on the panel, so the inner album art used to overflow past the corner radius. Inspecting current `MiniPlayerView.swift:28` — it sets `.frame(width: 342)` while the panel is `320`. That's a pre-existing inconsistency in the *main* popover.

Pick: standardize on `342` for both panels. The album art is 342 wide; the panel must match, otherwise the rounded clip and the shadow do not contain the art.

**Files:**
- Modify: `Sources/RPPlayer/Shell/PopoverController.swift`

- [ ] **Step 1: Update `PopoverController.contentSize`**

Change line 6:

```swift
static let contentSize = NSSize(width: 342, height: 540)
```

- [ ] **Step 2: Run all tests**

Run: `swift test`
Expected: 331 tests pass — popover tests don't assert on size.

- [ ] **Step 3: Manual verification**

Build and run: `./scripts/local-build-copy-open.sh` (or however the team launches a built `.app`). Click status icon. Confirm:
- Popover panel is 342 wide (no horizontal gap between art edge and panel edge).
- Rounded corners clip the album art top.
- Shadow follows the rounded shape.

If the script does not exist or the team uses a different command, document the fallback in the commit body. Report explicitly that UI was tested in a browser-equivalent (the running .app) per CLAUDE.md UI-testing rule.

- [ ] **Step 4: Commit**

```bash
git add Sources/RPPlayer/Shell/PopoverController.swift
git commit -m "fix(shell): align main popover panel width to album-art width (342)"
```

---

### Task 7: Fold `PastSongPopoverController` into shared base

`PopoverController` and `PastSongPopoverController` differ only in: (a) `PopoverController` supports floating mode + reuse via `setFloatingMode`; (b) `PastSongPopoverController` rebuilds its hosted view per `present`. Past-song behavior we want: a fresh hosting view per click (different song each time) but the same panel chrome / monitor logic.

**Decision:** add a `present(rootView:relativeTo:)` method to `PopoverController` that swaps the hosted view, then route the past-song flow through a separate `PopoverController` instance. Delete `PastSongPopoverController`.

**Files:**
- Modify: `Sources/RPPlayer/Shell/PopoverController.swift`
- Delete: `Sources/RPPlayer/Shell/PastSongPopoverController.swift`
- Delete: `Tests/RPPlayerTests/Shell/PastSongPopoverControllerTests.swift`
- Modify: `Sources/RPPlayer/App/AppContainer.swift`
- Modify: `Sources/RPPlayer/Shell/AppDelegate.swift`
- Modify: `Tests/RPPlayerTests/Shell/AppDelegateTests.swift`

- [ ] **Step 1: Add `present(rootView:relativeTo:)` to `PopoverController`**

Append a method below `show(relativeTo:)`:

```swift
func present(rootView: AnyView, relativeTo anchor: NSView) {
    let wrapped = AnyView(rootView.background(Color(nsColor: .windowBackgroundColor)))
    let hostingView = NSHostingView(rootView: wrapped)
    hostingView.frame = NSRect(origin: .zero, size: Self.contentSize)
    panel.contentView = hostingView
    panel.contentView?.wantsLayer = true
    panel.contentView?.layer?.cornerRadius = 10
    panel.contentView?.layer?.masksToBounds = true
    show(relativeTo: anchor)
}
```

- [ ] **Step 2: Update `AppContainer` to expose a second `PopoverController`**

In `Sources/RPPlayer/App/AppContainer.swift`:
- Rename property `pastSongPopoverController: PastSongPopoverController` → `pastSongPopoverController: PopoverController` (preserve the property name; only the type changes — call sites stay valid).
- In `live()`, replace `PastSongPopoverController()` (line 424) with `PopoverController(rootView: AnyView(EmptyView()))`.

- [ ] **Step 3: Update `AppDelegate.pastSongPresenter` call site**

In `Sources/RPPlayer/Shell/AppDelegate.swift`, replace the `present(viewModel:relativeTo:)` call (line 105) with:

```swift
container.pastSongPopoverController.present(
    rootView: AnyView(PastSongView(viewModel: viewModel)),
    relativeTo: anchor
)
```

The `viewModel` must outlive the panel: store it as a strong ref. The simplest place — bind it on `AppDelegate`:

```swift
private(set) var pastSongViewModel: PastSongViewModel?
```

And in the closure:
```swift
self?.pastSongViewModel = viewModel
container.pastSongPopoverController.present(
    rootView: AnyView(PastSongView(viewModel: viewModel)),
    relativeTo: anchor
)
```

(The closure captures `[weak self, weak statusItemController, container]`. Adjust capture list accordingly.)

- [ ] **Step 4: Delete `PastSongPopoverController.swift` and its test file**

```bash
rm Sources/RPPlayer/Shell/PastSongPopoverController.swift
rm Tests/RPPlayerTests/Shell/PastSongPopoverControllerTests.swift
```

- [ ] **Step 5: Update `AppDelegateTests.swift`**

Lines 59 and 142 construct `PastSongPopoverController()`. Replace with:

```swift
pastSongPopoverController: PopoverController(rootView: AnyView(EmptyView())),
```

- [ ] **Step 6: Build**

Run: `swift build`
Expected: build succeeds. If `pastSongPresenter` capture-semantics warnings appear (`@Sendable` + `weak self`), fix per Swift 6.2 strict concurrency by capturing `[weak self]` and reading on `MainActor`.

- [ ] **Step 7: Run all tests**

Run: `swift test`
Expected: 330 tests pass (was 331 — minus the deleted PastSongPopoverControllerTests file, assuming 1 test).

- [ ] **Step 8: Manual verification**

Build .app. Trigger a recent-song notification (or use the dev path that fires one). Click the notification. Confirm:
- Past-song popover renders with album art at 342×342.
- Title row has the same `.title3` typography as the main popover.
- If `ambientBackgroundEnabled = true` in settings, the past-song popover paints the ambient gradient.
- Outside-click and Esc both dismiss the popover.
- Opening the main popover after the past-song popover dismisses the past-song popover (mutual exclusion still works because the past-song closure calls `statusItemController?.closeIfShown()` before showing).

- [ ] **Step 9: Commit**

```bash
git add Sources/RPPlayer/Shell/PopoverController.swift Sources/RPPlayer/App/AppContainer.swift Sources/RPPlayer/Shell/AppDelegate.swift Tests/RPPlayerTests/Shell/AppDelegateTests.swift
git rm Sources/RPPlayer/Shell/PastSongPopoverController.swift Tests/RPPlayerTests/Shell/PastSongPopoverControllerTests.swift
git commit -m "refactor(shell): fold PastSongPopoverController into shared PopoverController"
```

---

### Task 8: Update `CLAUDE.md` PR table + technical decisions

**Files:**
- Modify: `CLAUDE.md`

- [ ] **Step 1: Add PR 23 row to the PR status table**

Insert below the PR 22 row:

```markdown
| 23   | merged to main | ✅      | Popover shared components: PopoverAlbumArt + SongTitleRow + AmbientGradientBackground extracted; PastSongView gets ambient gradient + matched typography; PastSongPopoverController folded into shared PopoverController via present(rootView:relativeTo:); main popover panel width corrected 320 → 342 |
```

(Mark `merged to main` only after the merge actually happens; until then leave as `claude/pr23-popover-shared-components`.)

- [ ] **Step 2: Add a "Last merged" line update**

Update the line near the top:

```markdown
- Last merged: **PR 23** — popover shared components + ambient parity. 330 tests passing on `main`.
```

- [ ] **Step 3: Add test count entry**

Append to the "Test counts by PR" list:

```markdown
- After PR 23 popover shared components (PopoverAlbumArt + SongTitleRow + AmbientGradientBackground; PastSongViewModel gets configStore + paletteExtractor + ambientTopColor; PastSongView renders ambient gradient; PastSongPopoverController removed in favor of `PopoverController.present(rootView:relativeTo:)`; main popover panel width corrected to 342): 330
```

(Adjust the actual test count if it differs from this plan's projection.)

- [ ] **Step 4: Update the "Shell (AppKit + SwiftUI)" technical-decisions section**

Add a new bullet near the existing popover bullets, e.g. after the bullet about `PopoverController` being non-`final`:

```markdown
- **Single popover-panel implementation.** `PopoverController` exposes `present(rootView:relativeTo:)` for callers that need to swap the hosted view per show (used by the notification-click past-song flow). The earlier `PastSongPopoverController` clone was deleted in PR 23 — both paths now share panel chrome (borderless NSPanel, 10pt corner radius, mouse / Esc dismissal monitors) and content size (342×540). The past-song view uses the same `PopoverAlbumArt` + `SongTitleRow` + `AmbientGradientBackground` shared components as `MiniPlayerView`.
```

Also update the bullet that mentions `PastSongPopoverController` (search for "PastSongPopoverController" in the file):
- Old: "`PastSongPopoverController` mirrors `PopoverController` (borderless `NSPanel` + 10pt corner radius) but rebuilds its hosted `NSHostingView<PastSongView>` per `present(viewModel:relativeTo:)`. Mutual exclusion ..."
- New: "Past-song popover uses `PopoverController.present(rootView:relativeTo:)` (the same controller class as the main popover). Mutual exclusion with the main popover is bidirectional — the past-song presenter calls `statusItemController.closeIfShown()` before showing; the main `mainPresenter` calls `pastSongPopoverController.close()` before toggling the main popover."

- [ ] **Step 5: Commit**

```bash
git add CLAUDE.md
git commit -m "docs: update CLAUDE.md for PR 23 popover shared components"
```

---

## Self-Review Checklist (already applied)

- **Spec coverage:**
  - "Same styling" → Tasks 1, 2 (PopoverAlbumArt, SongTitleRow with MiniPlayer typography).
  - "Same ambient color settings" → Tasks 3, 4, 5 (gradient extraction, viewmodel wiring, view consumption).
  - "Same panel chrome" → Tasks 6, 7 (panel width fix + shared `PopoverController`).
  - "Without active player elements" → past-song view skips transport / channel row / progress / hamburger / errors stream.
- **Placeholder scan:** all code blocks contain real code; no "TBD" / "similar to" references.
- **Type consistency:** `PastSongViewModel` constructor signature in Task 4 matches the call sites updated in Tasks 4, 7. `PopoverController.present(rootView:relativeTo:)` signature is identical between Task 7 step 1 and step 3. `AmbientGradientBackground(topColor:)` is consistent across Tasks 3, 5.

## Known Risks

- **Swift 6.2 strict concurrency** in Task 7's `pastSongPresenter` closure — the captured `[weak self]` plus `MainActor` annotation must align with how AppDelegate stores `pastSongViewModel`. If a build error appears, prefer storing the strong ref on `AppDelegate` rather than capturing it in the closure.
- **Panel width change (Task 6)** is a visible behavioral change in the *main* popover. If the team prefers to keep the main popover at 320 wide, adjust `MiniPlayerView`'s inner `.frame(width: 342)` instead. Confirm with user before merging.
- **Test count projection** is approximate. Adjust the final number in CLAUDE.md / commit messages to match the actual `swift test` output.

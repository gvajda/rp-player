# Upcoming Program Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add an "Upcoming Program" window that shows the next N songs per channel side-by-side, fetched read-only via `api/get_block`.

**Architecture:** `UpcomingProgramViewModel` fetches blocks for all enabled channels concurrently via a restored `RpApiClient.getBlock()`, assembles `UpcomingColumn` / `UpcomingSongRow` models with art + ambient palette, then exposes them to `UpcomingProgramView` (horizontal scroll, compact cards with flush art and left→right ambient gradient). `UpcomingWindowController` wraps the view in a standard `NSWindow`. The hamburger menu in the popover opens the window. Settings gain two new fields: `upcomingRowCount` (3–10) and `upcomingHiddenChannelIds`.

**Tech Stack:** Swift 6.2, SwiftUI, AppKit, existing `AlbumArtCache` / `AmbientPaletteExtractor` / `BlockSongs` utilities, `MockRpApiClient` test double.

---

## File map

| Path | Action | Responsibility |
| ---- | ------ | -------------- |
| `Sources/RPPlayer/Api/RpApiClient.swift` | modify | Re-add `getBlock(channel:bitrate:)` to protocol + `LiveRpApiClient` |
| `Tests/RPPlayerTests/Playback/MockRpApiClient.swift` | modify | Add `getBlock` call case + response queue |
| `Tests/RPPlayerTests/Api/RpApiClientTests.swift` | modify | URL-shape test for `getBlock` |
| `Sources/RPPlayer/Config/AppSettings.swift` | modify | Add `upcomingRowCount`, `upcomingHiddenChannelIds` |
| `Tests/RPPlayerTests/Config/AppSettingsCodableTests.swift` | modify | Backward-compat decode tests |
| `Sources/RPPlayer/Notifications/AlbumArtCache.swift` | modify | Bump `defaultMaxFiles` 20 → 100 |
| `Sources/RPPlayer/Upcoming/UpcomingProgramViewModel.swift` | create | Models + VM |
| `Tests/RPPlayerTests/Upcoming/UpcomingProgramViewModelTests.swift` | create | VM unit tests |
| `Sources/RPPlayer/Upcoming/UpcomingProgramView.swift` | create | SwiftUI card / column / root views |
| `Sources/RPPlayer/Upcoming/UpcomingWindowController.swift` | create | `NSWindow` wrapper |
| `Sources/RPPlayer/Shell/SettingsViewModel.swift` | modify | Add upcoming row-count, hidden-channel-ids, channel list |
| `Sources/RPPlayer/Shell/SettingsView.swift` | modify | "Upcoming Program" settings section |
| `Sources/RPPlayer/Shell/MiniPlayerViewModel.swift` | modify | Add `upcomingAction` closure |
| `Sources/RPPlayer/Shell/MiniPlayerView.swift` | modify | "Upcoming Program…" hamburger item |
| `Sources/RPPlayer/App/AppContainer.swift` | modify | Wire `UpcomingWindowController`, bind closure |

---

## Task 1: Restore `getBlock` on `RpApiClient`

**Files:**
- Modify: `Sources/RPPlayer/Api/RpApiClient.swift`
- Modify: `Tests/RPPlayerTests/Playback/MockRpApiClient.swift`
- Modify: `Tests/RPPlayerTests/Api/RpApiClientTests.swift`

- [ ] **Step 1: Write the failing URL test**

Add to `Tests/RPPlayerTests/Api/RpApiClientTests.swift` (inside the `RpApiClientTests` class, after `testPlayBootstrapBuildsCorrectURL`):

```swift
func testGetBlockBuildsCorrectURL() async throws {
    var components = URLComponents(
        url: baseURL.appendingPathComponent("api/get_block"),
        resolvingAgainstBaseURL: false)!
    components.queryItems = [
        URLQueryItem(name: "bitrate", value: "4"),
        URLQueryItem(name: "chan", value: "2"),
        URLQueryItem(name: "info", value: "true"),
    ]
    StubURLProtocol.register(url: components.url!, body: try loadFixture("get_block"))

    let client = makeClient()
    let block = try await client.getBlock(channel: 2, bitrate: 4)
    XCTAssertFalse(block.song.isEmpty)
}
```

- [ ] **Step 2: Run test to confirm it fails**

```bash
swift test --filter RpApiClientTests/testGetBlockBuildsCorrectURL 2>&1 | tail -5
```

Expected: compile error — `value of type 'LiveRpApiClient' has no member 'getBlock'`

- [ ] **Step 3: Add `getBlock` to `RpApiClient` protocol**

In `Sources/RPPlayer/Api/RpApiClient.swift`, add after the `play(...)` method in the `RpApiClient` protocol:

```swift
func getBlock(channel: Int, bitrate: Int) async throws -> GetBlock
```

- [ ] **Step 4: Add `getBlock` implementation to `LiveRpApiClient`**

In `Sources/RPPlayer/Api/RpApiClient.swift`, add after `LiveRpApiClient.play(...)`:

```swift
public func getBlock(channel: Int, bitrate: Int) async throws -> GetBlock {
    let query: [String: String] = [
        "bitrate": String(bitrate),
        "chan": String(channel),
        "info": "true",
    ]
    return try await get(path: "api/get_block", query: query)
}
```

- [ ] **Step 5: Add `getBlock` to `MockRpApiClient`**

In `Tests/RPPlayerTests/Playback/MockRpApiClient.swift`:

Add `.getBlock(channel: Int, bitrate: Int)` to the `Call` enum:

```swift
case getBlock(channel: Int, bitrate: Int)
```

Add stored properties after `var blockResponses`:

```swift
var getBlockResponses: [GetBlock] = []
var getBlockError: Error?
```

Add setter and the method implementation (after `setBlockResponses`):

```swift
func setGetBlockResponses(_ responses: [GetBlock]) {
    self.getBlockResponses = responses
    self.getBlockError = nil
}

func setGetBlockError(_ error: Error) {
    self.getBlockError = error
}

func getBlock(channel: Int, bitrate: Int) async throws -> GetBlock {
    calls.append(.getBlock(channel: channel, bitrate: bitrate))
    if let error = getBlockError { throw error }
    guard !getBlockResponses.isEmpty else {
        throw RpApiError.network(URLError(.unknown))
    }
    return getBlockResponses.removeFirst()
}
```

- [ ] **Step 6: Run test to confirm it passes**

```bash
swift test --filter RpApiClientTests/testGetBlockBuildsCorrectURL 2>&1 | tail -5
```

Expected: `Test Suite 'RpApiClientTests' passed`

- [ ] **Step 7: Commit**

```bash
git add Sources/RPPlayer/Api/RpApiClient.swift \
        Tests/RPPlayerTests/Playback/MockRpApiClient.swift \
        Tests/RPPlayerTests/Api/RpApiClientTests.swift
git commit -m "feat(api): restore getBlock(channel:bitrate:) as read-only block fetch

api/play sends playback-started telemetry; api/get_block is the side-effect-free alternative needed by the upcoming program view."
```

---

## Task 2: `AppSettings` new fields + backward-compat tests

**Files:**
- Modify: `Sources/RPPlayer/Config/AppSettings.swift`
- Modify: `Tests/RPPlayerTests/Config/AppSettingsCodableTests.swift`

- [ ] **Step 1: Write the failing tests**

Add to `Tests/RPPlayerTests/Config/AppSettingsCodableTests.swift`:

```swift
func testMissingUpcomingRowCountDecodesAsFive() throws {
    let json = #"{"selectedChannelId":0}"#.data(using: .utf8)!
    let decoded = try JSONDecoder().decode(AppSettings.self, from: json)
    XCTAssertEqual(decoded.upcomingRowCount, 5)
}

func testMissingUpcomingHiddenChannelIdsDecodesAsEmpty() throws {
    let json = #"{"selectedChannelId":0}"#.data(using: .utf8)!
    let decoded = try JSONDecoder().decode(AppSettings.self, from: json)
    XCTAssertEqual(decoded.upcomingHiddenChannelIds, [])
}

func testUpcomingRowCountRoundTrips() throws {
    var settings = AppSettings.default
    settings.upcomingRowCount = 8
    let data = try JSONEncoder().encode(settings)
    let decoded = try JSONDecoder().decode(AppSettings.self, from: data)
    XCTAssertEqual(decoded.upcomingRowCount, 8)
}

func testUpcomingHiddenChannelIdsRoundTrips() throws {
    var settings = AppSettings.default
    settings.upcomingHiddenChannelIds = [1, 3]
    let data = try JSONEncoder().encode(settings)
    let decoded = try JSONDecoder().decode(AppSettings.self, from: data)
    XCTAssertEqual(decoded.upcomingHiddenChannelIds, [1, 3])
}
```

- [ ] **Step 2: Run tests to confirm they fail**

```bash
swift test --filter AppSettingsCodableTests 2>&1 | tail -5
```

Expected: compile error — `AppSettings` has no member `upcomingRowCount`

- [ ] **Step 3: Add fields to `AppSettings`**

In `Sources/RPPlayer/Config/AppSettings.swift`, add after `var playerId`:

```swift
/// Number of upcoming songs to display per channel in the Upcoming Program window. Range 3–10.
public var upcomingRowCount: Int
/// Channel IDs the user has hidden in the Upcoming Program view. Chan 42 and 99 are always
/// excluded in the UI regardless of this list.
public var upcomingHiddenChannelIds: [Int]
```

In the `init(...)` method, add parameters with defaults:

```swift
upcomingRowCount: Int = 5,
upcomingHiddenChannelIds: [Int] = []
```

And the assignments:

```swift
self.upcomingRowCount = upcomingRowCount
self.upcomingHiddenChannelIds = upcomingHiddenChannelIds
```

In `init(from decoder:)`, add after the `playerId` decode line:

```swift
self.upcomingRowCount = try c.decodeIfPresent(Int.self, forKey: .upcomingRowCount) ?? 5
self.upcomingHiddenChannelIds = try c.decodeIfPresent([Int].self, forKey: .upcomingHiddenChannelIds) ?? []
```

- [ ] **Step 4: Run tests to confirm they pass**

```bash
swift test --filter AppSettingsCodableTests 2>&1 | tail -5
```

Expected: all pass

- [ ] **Step 5: Commit**

```bash
git add Sources/RPPlayer/Config/AppSettings.swift \
        Tests/RPPlayerTests/Config/AppSettingsCodableTests.swift
git commit -m "feat(settings): add upcomingRowCount and upcomingHiddenChannelIds"
```

---

## Task 3: Bump `AlbumArtCache.defaultMaxFiles` to 100

**Files:**
- Modify: `Sources/RPPlayer/Notifications/AlbumArtCache.swift`

- [ ] **Step 1: Change the constant**

In `Sources/RPPlayer/Notifications/AlbumArtCache.swift`, replace:

```swift
public static let defaultMaxFiles = 20
```

with:

```swift
public static let defaultMaxFiles = 100
```

- [ ] **Step 2: Verify build**

```bash
swift build 2>&1 | tail -5
```

Expected: `Build complete!`

- [ ] **Step 3: Commit**

```bash
git add Sources/RPPlayer/Notifications/AlbumArtCache.swift
git commit -m "feat(cache): increase album art cache cap to 100 files for upcoming program"
```

---

## Task 4: `UpcomingProgramViewModel` + models (TDD)

**Files:**
- Create: `Sources/RPPlayer/Upcoming/UpcomingProgramViewModel.swift`
- Create: `Tests/RPPlayerTests/Upcoming/UpcomingProgramViewModelTests.swift`

- [ ] **Step 1: Create the test file with all failing tests**

Create `Tests/RPPlayerTests/Upcoming/UpcomingProgramViewModelTests.swift`:

```swift
import XCTest
import SwiftUI
@testable import RPPlayer

@MainActor
final class UpcomingProgramViewModelTests: XCTestCase {
    // MARK: - Helpers

    private func makeChannel(id: Int) -> Channel {
        Channel(chan: String(id), title: "Channel \(id)", streamName: nil,
                bannerUrl: nil, slug: nil, image: nil)
    }

    private func makeBlock(songs: Int = 3) -> GetBlock {
        let songDict: [String: PlayListSong] = Dictionary(
            uniqueKeysWithValues: (0..<songs).map { i in
                let song = PlayListSong(
                    songId: "song\(i)", type: "M", artist: "Artist \(i)",
                    title: "Title \(i)", album: "Album \(i)",
                    elapsed: i * 60_000, duration: 60_000,
                    slideshow: nil, sliceNum: nil, event: nil,
                    userRating: nil, rating: nil, cover: nil
                )
                return (String(i), song)
            }
        )
        return GetBlock(
            url: "https://stream.example.com/stream",
            chan: "0",
            bitrate: "flac",
            cue: 0,
            expiration: 9_999_999_999,
            length: nil,
            imageBase: "https://img.radioparadise.com/",
            song: songDict,
            channel: nil,
            event: "123",
            endEvent: "456",
            type: "M",
            ext: nil
        )
    }

    private func makeVM(
        api: MockRpApiClient,
        configStore: StubConfigStore = StubConfigStore(initial: .default),
        artCache: StubAlbumArtCache = StubAlbumArtCache(),
        palette: StubAmbientPaletteExtractor = StubAmbientPaletteExtractor()
    ) -> UpcomingProgramViewModel {
        UpcomingProgramViewModel(
            api: api,
            albumArtCache: artCache,
            configStore: configStore,
            paletteExtractor: palette
        )
    }

    // MARK: - Tests

    func testLoadPopulatesColumns() async throws {
        let api = MockRpApiClient()
        let channels = [makeChannel(id: 0), makeChannel(id: 1)]
        await api.setListChannelsResponse(channels)
        await api.setGetBlockResponses([makeBlock(songs: 5), makeBlock(songs: 5)])

        var settings = AppSettings.default
        settings.upcomingRowCount = 3
        let vm = makeVM(api: api, configStore: StubConfigStore(initial: settings))
        await vm.load()

        XCTAssertEqual(vm.columns.count, 2)
        XCTAssertEqual(vm.columns[0].songs.count, 3)
        XCTAssertEqual(vm.columns[1].songs.count, 3)
    }

    func testLoadSkipsHiddenChannels() async throws {
        let api = MockRpApiClient()
        let channels = [makeChannel(id: 0), makeChannel(id: 1), makeChannel(id: 2)]
        await api.setListChannelsResponse(channels)
        await api.setGetBlockResponses([makeBlock(), makeBlock()])

        var settings = AppSettings.default
        settings.upcomingHiddenChannelIds = [1]
        let vm = makeVM(api: api, configStore: StubConfigStore(initial: settings))
        await vm.load()

        XCTAssertEqual(vm.columns.count, 2)
        XCTAssertFalse(vm.columns.contains { $0.id == 1 })
    }

    func testLoadAlwaysExcludesChannel42And99() async throws {
        let api = MockRpApiClient()
        let channels = [makeChannel(id: 0), makeChannel(id: 42), makeChannel(id: 99)]
        await api.setListChannelsResponse(channels)
        await api.setGetBlockResponses([makeBlock()])

        let vm = makeVM(api: api)
        await vm.load()

        XCTAssertEqual(vm.columns.count, 1)
        XCTAssertEqual(vm.columns[0].id, 0)
    }

    func testLoadSetsLastUpdated() async throws {
        let api = MockRpApiClient()
        await api.setListChannelsResponse([makeChannel(id: 0)])
        await api.setGetBlockResponses([makeBlock()])

        let vm = makeVM(api: api)
        XCTAssertNil(vm.lastUpdated)
        await vm.load()
        XCTAssertNotNil(vm.lastUpdated)
    }

    func testLoadIsNotLoadingAfterCompletion() async throws {
        let api = MockRpApiClient()
        await api.setListChannelsResponse([makeChannel(id: 0)])
        await api.setGetBlockResponses([makeBlock()])

        let vm = makeVM(api: api)
        await vm.load()
        XCTAssertFalse(vm.isLoading)
    }

    func testRefreshReplacesColumns() async throws {
        let api = MockRpApiClient()
        let channels = [makeChannel(id: 0)]
        await api.setListChannelsResponse(channels)
        await api.setGetBlockResponses([makeBlock(songs: 2)])

        let vm = makeVM(api: api)
        await vm.load()
        XCTAssertEqual(vm.columns[0].songs.count, 2)

        await api.setListChannelsResponse(channels)
        await api.setGetBlockResponses([makeBlock(songs: 4)])
        await vm.load()
        XCTAssertEqual(vm.columns[0].songs.count, 4)
    }

    func testChannelFetchErrorProducesEmptyColumnAndSetsErrorMessage() async throws {
        let api = MockRpApiClient()
        let channels = [makeChannel(id: 0), makeChannel(id: 1)]
        await api.setListChannelsResponse(channels)
        // Only one block response: channel 0 succeeds, channel 1 gets the error response
        await api.setGetBlockError(RpApiError.network(URLError(.notConnectedToInternet)))

        let vm = makeVM(api: api)
        await vm.load()

        XCTAssertNotNil(vm.errorMessage)
        // All columns present but all empty due to error
        XCTAssertTrue(vm.columns.allSatisfy { $0.songs.isEmpty })
    }

    func testLoadCapsRowsAtUpcomingRowCount() async throws {
        let api = MockRpApiClient()
        await api.setListChannelsResponse([makeChannel(id: 0)])
        await api.setGetBlockResponses([makeBlock(songs: 10)])

        var settings = AppSettings.default
        settings.upcomingRowCount = 4
        let vm = makeVM(api: api, configStore: StubConfigStore(initial: settings))
        await vm.load()

        XCTAssertEqual(vm.columns[0].songs.count, 4)
    }
}
```

- [ ] **Step 2: Run tests to confirm they fail to compile**

```bash
swift test --filter UpcomingProgramViewModelTests 2>&1 | tail -10
```

Expected: compile error — `UpcomingProgramViewModel` not found

- [ ] **Step 3: Create `UpcomingProgramViewModel.swift`**

Create `Sources/RPPlayer/Upcoming/UpcomingProgramViewModel.swift`:

```swift
import AppKit
import SwiftUI

struct UpcomingColumn: Identifiable, Sendable {
    let id: Int
    let channel: Channel
    let songs: [UpcomingSongRow]
}

struct UpcomingSongRow: Identifiable, Sendable {
    let id: String
    let song: PlayListSong
    var art: NSImage?
    var ambientColor: Color = Color(nsColor: .windowBackgroundColor)
}

@MainActor
final class UpcomingProgramViewModel: ObservableObject {
    @Published private(set) var columns: [UpcomingColumn] = []
    @Published private(set) var isLoading = false
    @Published private(set) var lastUpdated: Date?
    @Published private(set) var errorMessage: String?

    private let api: any RpApiClient
    private let albumArtCache: any AlbumArtCache
    private let configStore: any ConfigStore
    private let paletteExtractor: any AmbientPaletteExtracting

    init(
        api: any RpApiClient,
        albumArtCache: any AlbumArtCache,
        configStore: any ConfigStore,
        paletteExtractor: any AmbientPaletteExtracting
    ) {
        self.api = api
        self.albumArtCache = albumArtCache
        self.configStore = configStore
        self.paletteExtractor = paletteExtractor
    }

    func load() async {
        isLoading = true
        errorMessage = nil

        let settings = await configStore.settings
        let rowCount = settings.upcomingRowCount
        let hiddenIds = Set(settings.upcomingHiddenChannelIds)
        let bitrate = settings.bitrate

        let allChannels: [Channel]
        do {
            allChannels = try await api.listChannels()
        } catch {
            errorMessage = "Failed to load channels."
            isLoading = false
            return
        }

        let enabledChannels = allChannels.filter {
            guard let id = Int($0.chan) else { return false }
            return id != 42 && id != 99 && !hiddenIds.contains(id)
        }

        // Fetch all blocks concurrently, preserving channel order.
        let api = self.api
        var blockResults: [(Int, Channel, GetBlock?)] = []
        await withTaskGroup(of: (Int, Channel, GetBlock?).self) { group in
            for (i, channel) in enabledChannels.enumerated() {
                guard let chanId = Int(channel.chan) else { continue }
                group.addTask {
                    let block = try? await api.getBlock(channel: chanId, bitrate: bitrate)
                    return (i, channel, block)
                }
            }
            for await result in group {
                blockResults.append(result)
            }
        }
        blockResults.sort { $0.0 < $1.0 }

        if blockResults.contains(where: { $0.2 == nil }) {
            errorMessage = "Some channels could not be loaded."
        }

        struct ColStub {
            let channel: Channel
            var rows: [UpcomingSongRow]
        }

        var stubs: [ColStub] = blockResults.map { _, channel, block in
            guard let block else { return ColStub(channel: channel, rows: []) }
            let songs = Array(BlockSongs.orderedSongs(from: block).prefix(rowCount))
            let rows = songs.map { UpcomingSongRow(id: $0.songId, song: $0) }
            return ColStub(channel: channel, rows: rows)
        }

        // Load art + ambient palette for every row concurrently.
        let albumArtCache = self.albumArtCache
        let paletteExtractor = self.paletteExtractor
        await withTaskGroup(of: (Int, Int, NSImage?, Color).self) { group in
            for (ci, stub) in stubs.enumerated() {
                for (ri, row) in stub.rows.enumerated() {
                    guard let cover = row.song.cover, !cover.isEmpty else { continue }
                    group.addTask {
                        let image = await albumArtCache.image(for: cover)
                        var color = Color(nsColor: .windowBackgroundColor)
                        if let img = image,
                           let extracted = await paletteExtractor.extractBottomEdgeColor(from: img) {
                            color = extracted.swiftUIColor
                        }
                        return (ci, ri, image, color)
                    }
                }
            }
            for await (ci, ri, image, color) in group {
                stubs[ci].rows[ri].art = image
                stubs[ci].rows[ri].ambientColor = color
            }
        }

        columns = stubs.compactMap { stub in
            guard let id = Int(stub.channel.chan) else { return nil }
            return UpcomingColumn(id: id, channel: stub.channel, songs: stub.rows)
        }
        isLoading = false
        lastUpdated = Date()
    }

    func refresh() {
        Task { await load() }
    }
}
```

- [ ] **Step 4: Run tests to confirm they pass**

```bash
swift test --filter UpcomingProgramViewModelTests 2>&1 | tail -10
```

Expected: all 7 tests pass

- [ ] **Step 5: Commit**

```bash
git add Sources/RPPlayer/Upcoming/UpcomingProgramViewModel.swift \
        Tests/RPPlayerTests/Upcoming/UpcomingProgramViewModelTests.swift
git commit -m "feat(upcoming): UpcomingProgramViewModel + models with full test coverage"
```

---

## Task 5: `UpcomingProgramView` (SwiftUI)

**Files:**
- Create: `Sources/RPPlayer/Upcoming/UpcomingProgramView.swift`

No unit tests — pure SwiftUI layout.

- [ ] **Step 1: Create the view file**

Create `Sources/RPPlayer/Upcoming/UpcomingProgramView.swift`:

```swift
import AppKit
import SwiftUI

// MARK: - Song card

struct UpcomingSongCardView: View {
    let row: UpcomingSongRow

    var body: some View {
        HStack(spacing: 0) {
            artView
            textArea
        }
        .frame(height: 68)
        .cornerRadius(8)
        .clipped()
    }

    @ViewBuilder
    private var artView: some View {
        if let image = row.art {
            Image(nsImage: image)
                .resizable()
                .scaledToFill()
                .frame(width: 68, height: 68)
                .clipped()
        } else {
            Color(nsColor: .separatorColor)
                .frame(width: 68, height: 68)
        }
    }

    private var textArea: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .center, spacing: 4) {
                Text(row.song.title)
                    .font(.system(size: 11, weight: .semibold))
                    .lineLimit(1)
                    .foregroundStyle(.primary)
                Spacer(minLength: 0)
                if let rating = row.song.userRating,
                   let value = Int(rating), value > 0 {
                    Text("★ \(value)")
                        .font(.system(size: 10))
                        .foregroundStyle(.yellow)
                }
            }
            Text(row.song.artist)
                .font(.system(size: 10))
                .lineLimit(1)
                .foregroundStyle(.secondary)
                .padding(.top, 2)
            if let album = row.song.album, !album.isEmpty {
                Text(album)
                    .font(.system(size: 9))
                    .lineLimit(1)
                    .foregroundStyle(.secondary)
                    .padding(.top, 1)
            }
        }
        .padding(.horizontal, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            LinearGradient(
                colors: [row.ambientColor.opacity(0.28),
                         Color(nsColor: .windowBackgroundColor)],
                startPoint: .leading,
                endPoint: .trailing
            )
        )
    }
}

// MARK: - Skeleton card (loading placeholder)

private struct SkeletonCardView: View {
    let index: Int
    @State private var opacity: Double = 1.0

    var body: some View {
        HStack(spacing: 0) {
            Color(nsColor: .separatorColor)
                .frame(width: 68, height: 68)
            VStack(alignment: .leading, spacing: 5) {
                RoundedRectangle(cornerRadius: 3)
                    .fill(Color(nsColor: .separatorColor))
                    .frame(width: 140, height: 9)
                RoundedRectangle(cornerRadius: 3)
                    .fill(Color(nsColor: .separatorColor))
                    .frame(width: 100, height: 8)
                RoundedRectangle(cornerRadius: 3)
                    .fill(Color(nsColor: .separatorColor))
                    .frame(width: 80, height: 7)
            }
            .padding(.horizontal, 10)
        }
        .frame(height: 68)
        .cornerRadius(8)
        .clipped()
        .opacity(opacity)
        .onAppear {
            withAnimation(
                .easeInOut(duration: 0.9)
                .repeatForever(autoreverses: true)
                .delay(Double(index % 5) * 0.1)
            ) {
                opacity = 0.35
            }
        }
    }
}

// MARK: - Column view

struct UpcomingColumnView: View {
    let column: UpcomingColumn

    var body: some View {
        VStack(alignment: .center, spacing: 6) {
            Text(column.channel.title)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Color.accentColor)
                .frame(maxWidth: .infinity, alignment: .center)
            VStack(spacing: 4) {
                ForEach(column.songs) { row in
                    UpcomingSongCardView(row: row)
                }
            }
        }
        .frame(width: 226)
    }
}

private struct SkeletonColumnView: View {
    let title: String
    let rowCount: Int

    var body: some View {
        VStack(alignment: .center, spacing: 6) {
            Text(title)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Color(nsColor: .tertiaryLabelColor))
                .frame(maxWidth: .infinity, alignment: .center)
            VStack(spacing: 4) {
                ForEach(0..<rowCount, id: \.self) { i in
                    SkeletonCardView(index: i)
                }
            }
        }
        .frame(width: 226)
    }
}

// MARK: - Root view

struct UpcomingProgramView: View {
    @ObservedObject var viewModel: UpcomingProgramViewModel
    let skeletonColumnCount: Int
    let skeletonRowCount: Int

    init(viewModel: UpcomingProgramViewModel,
         skeletonColumnCount: Int = 4,
         skeletonRowCount: Int = 5) {
        self.viewModel = viewModel
        self.skeletonColumnCount = skeletonColumnCount
        self.skeletonRowCount = skeletonRowCount
    }

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            ScrollView(.horizontal, showsIndicators: true) {
                LazyHStack(alignment: .top, spacing: 6) {
                    if viewModel.isLoading {
                        ForEach(0..<skeletonColumnCount, id: \.self) { i in
                            SkeletonColumnView(
                                title: "Loading…",
                                rowCount: skeletonRowCount
                            )
                        }
                    } else {
                        ForEach(viewModel.columns) { column in
                            UpcomingColumnView(column: column)
                        }
                    }
                }
                .padding(10)
            }
        }
        .task { await viewModel.load() }
    }

    private var toolbar: some View {
        HStack(spacing: 8) {
            if let error = viewModel.errorMessage {
                Label(error, systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer()
            if let date = viewModel.lastUpdated {
                Text(date, style: .relative)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            if viewModel.isLoading {
                ProgressView()
                    .controlSize(.small)
            } else {
                Button {
                    viewModel.refresh()
                } label: {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 13))
                }
                .buttonStyle(.borderless)
                .help("Refresh")
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .frame(height: 38)
    }
}
```

- [ ] **Step 2: Verify it builds**

```bash
swift build 2>&1 | tail -5
```

Expected: `Build complete!`

- [ ] **Step 3: Commit**

```bash
git add Sources/RPPlayer/Upcoming/UpcomingProgramView.swift
git commit -m "feat(upcoming): UpcomingProgramView with card, column, skeleton, and toolbar"
```

---

## Task 6: `UpcomingWindowController`

**Files:**
- Create: `Sources/RPPlayer/Upcoming/UpcomingWindowController.swift`

- [ ] **Step 1: Create the controller**

Create `Sources/RPPlayer/Upcoming/UpcomingWindowController.swift`:

```swift
import AppKit
import SwiftUI

@MainActor
final class UpcomingWindowController {
    private let viewModel: UpcomingProgramViewModel
    private var window: NSWindow?

    init(viewModel: UpcomingProgramViewModel) {
        self.viewModel = viewModel
    }

    func show() {
        if window == nil {
            let rootView = UpcomingProgramView(viewModel: viewModel)
            let hosting = NSHostingController(rootView: rootView)
            let w = NSWindow(contentViewController: hosting)
            w.title = "Upcoming Program"
            w.styleMask = [.titled, .closable, .miniaturizable, .resizable]
            w.setContentSize(NSSize(width: 720, height: 480))
            w.minSize = NSSize(width: 480, height: 300)
            w.setFrameAutosaveName("UpcomingProgram")
            window = w
        }
        window?.makeKeyAndOrderFront(nil)
    }
}
```

- [ ] **Step 2: Verify it builds**

```bash
swift build 2>&1 | tail -5
```

Expected: `Build complete!`

- [ ] **Step 3: Commit**

```bash
git add Sources/RPPlayer/Upcoming/UpcomingWindowController.swift
git commit -m "feat(upcoming): UpcomingWindowController wrapping NSWindow"
```

---

## Task 7: `SettingsViewModel` + `SettingsView` new section

**Files:**
- Modify: `Sources/RPPlayer/Shell/SettingsViewModel.swift`
- Modify: `Sources/RPPlayer/Shell/SettingsView.swift`

- [ ] **Step 1: Add upcoming fields to `SettingsViewModel`**

In `Sources/RPPlayer/Shell/SettingsViewModel.swift`:

Add these `@Published` properties after `ambientBackgroundEnabled`:

```swift
@Published private(set) var upcomingRowCount: Int
@Published private(set) var upcomingHiddenChannelIds: [Int]
@Published private(set) var upcomingChannels: [Channel] = []
```

Add `listChannels` closure parameter to `init` (with a default so existing callers don't break):

```swift
private let listChannels: @Sendable () async throws -> [Channel]
```

In `init(...)`, add the parameter:

```swift
init(
    configStore: any ConfigStore,
    deviceCatalog: any AudioDeviceCatalog,
    auth: any KeychainAuth,
    openLoginWindow: @escaping @MainActor () -> Void,
    openApplicationData: @escaping @MainActor () -> Void,
    listChannels: @Sendable @escaping () async throws -> [Channel] = { [] }
) {
```

Add `self.listChannels = listChannels` in the init body.

Seed the two new properties from `AppSettings.default` in init:

```swift
self.upcomingRowCount = snapshot.upcomingRowCount
self.upcomingHiddenChannelIds = snapshot.upcomingHiddenChannelIds
```

In `start()`, update the config subscription block to include the new fields:

```swift
self.upcomingRowCount = snapshot.upcomingRowCount
self.upcomingHiddenChannelIds = snapshot.upcomingHiddenChannelIds
```

Also in `start()`, after `refreshAuthState()`, spawn a task to load channels:

```swift
Task { [weak self] in
    guard let self else { return }
    let channels = (try? await listChannels()) ?? []
    let filtered = channels.filter {
        guard let id = Int($0.chan) else { return false }
        return id != 42 && id != 99
    }
    await MainActor.run { self.upcomingChannels = filtered }
}
```

Add setter methods (after `setAmbientBackgroundEnabled`):

```swift
func setUpcomingRowCount(_ value: Int) async {
    await update { $0.upcomingRowCount = value }
}

func setChannelHidden(_ channelId: Int, _ hidden: Bool) async {
    await update { settings in
        if hidden {
            if !settings.upcomingHiddenChannelIds.contains(channelId) {
                settings.upcomingHiddenChannelIds.append(channelId)
            }
        } else {
            settings.upcomingHiddenChannelIds.removeAll { $0 == channelId }
        }
    }
}
```

- [ ] **Step 2: Add "Upcoming Program" section to `SettingsView`**

In `Sources/RPPlayer/Shell/SettingsView.swift`, locate the section containing the ambient background toggle. After that section (before the logging section), add:

```swift
Section("Upcoming Program") {
    Stepper("Rows: \(viewModel.upcomingRowCount)",
            value: Binding(
                get: { viewModel.upcomingRowCount },
                set: { v in Task { await viewModel.setUpcomingRowCount(v) } }
            ),
            in: 3...10)
    if !viewModel.upcomingChannels.isEmpty {
        ForEach(viewModel.upcomingChannels, id: \.chan) { channel in
            let chanId = Int(channel.chan) ?? -1
            Toggle(
                channel.title,
                isOn: Binding(
                    get: { !viewModel.upcomingHiddenChannelIds.contains(chanId) },
                    set: { visible in
                        Task { await viewModel.setChannelHidden(chanId, !visible) }
                    }
                )
            )
        }
    }
}
```

- [ ] **Step 3: Verify build and tests pass**

```bash
swift build 2>&1 | tail -5 && swift test 2>&1 | tail -5
```

Expected: `Build complete!` and all tests pass

- [ ] **Step 4: Commit**

```bash
git add Sources/RPPlayer/Shell/SettingsViewModel.swift \
        Sources/RPPlayer/Shell/SettingsView.swift
git commit -m "feat(settings): Upcoming Program section — row count stepper + channel visibility toggles"
```

---

## Task 8: `MiniPlayerViewModel` `upcomingAction` + `MiniPlayerView` menu item

**Files:**
- Modify: `Sources/RPPlayer/Shell/MiniPlayerViewModel.swift`
- Modify: `Sources/RPPlayer/Shell/MiniPlayerView.swift`

- [ ] **Step 1: Add `upcomingAction` to `MiniPlayerViewModel`**

In `Sources/RPPlayer/Shell/MiniPlayerViewModel.swift`, add after `showPopoverIfNeeded`:

```swift
var upcomingAction: @MainActor () -> Void = {}
```

Add a public call-through method (after `openSettings()`):

```swift
func openUpcoming() {
    upcomingAction()
}
```

- [ ] **Step 2: Add menu item to `MiniPlayerView`**

In `Sources/RPPlayer/Shell/MiniPlayerView.swift`, inside the `Section("RP Player")` block (the hamburger menu), add after `Button("Settings…")`:

```swift
Button("Upcoming Program…") { viewModel.openUpcoming() }
```

- [ ] **Step 3: Verify build and tests**

```bash
swift build 2>&1 | tail -5 && swift test 2>&1 | tail -5
```

Expected: `Build complete!` and all tests pass

- [ ] **Step 4: Commit**

```bash
git add Sources/RPPlayer/Shell/MiniPlayerViewModel.swift \
        Sources/RPPlayer/Shell/MiniPlayerView.swift
git commit -m "feat(upcoming): add Upcoming Program… to hamburger menu"
```

---

## Task 9: `AppContainer` wiring

**Files:**
- Modify: `Sources/RPPlayer/App/AppContainer.swift`

- [ ] **Step 1: Add `upcomingWindowController` stored property**

In `Sources/RPPlayer/App/AppContainer.swift`, add after `pastSongPopoverController`:

```swift
let upcomingWindowController: UpcomingWindowController
```

Add it to `init(...)` parameters:

```swift
upcomingWindowController: UpcomingWindowController,
```

And assignment:

```swift
self.upcomingWindowController = upcomingWindowController
```

- [ ] **Step 2: Wire in `live()`**

In `AppContainer.live()`:

Update the `SettingsViewModel` construction to pass the `listChannels` closure:

```swift
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
    listChannels: { try await api.listChannels() }
)
```

After `let viewModel = MiniPlayerViewModel(...)`, create the upcoming controller and bind the action:

```swift
let upcomingViewModel = UpcomingProgramViewModel(
    api: api,
    albumArtCache: cache,
    configStore: store ?? NoopConfigStore(),
    paletteExtractor: AmbientPaletteExtractor()
)
let upcomingWindowController = UpcomingWindowController(viewModel: upcomingViewModel)
viewModel.upcomingAction = { [upcomingWindowController] in upcomingWindowController.show() }
```

Add `upcomingWindowController` to the `AppContainer(...)` return:

```swift
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
```

- [ ] **Step 3: Update `AppContainerTests` if it constructs `AppContainer` directly**

Check whether `AppContainerTests` constructs `AppContainer` with explicit parameters. If so, add `upcomingWindowController: UpcomingWindowController(viewModel: UpcomingProgramViewModel(api: ..., albumArtCache: ..., configStore: ..., paletteExtractor: StubAmbientPaletteExtractor()))`.

```bash
grep -n "AppContainer(" Tests/RPPlayerTests/App/AppContainerTests.swift | head -5
```

If it uses a stub `AppContainer.init(...)` with explicit parameters, add the missing parameter. If it uses `AppContainer.live()`, no change is needed.

- [ ] **Step 4: Verify full build and test suite**

```bash
swift build 2>&1 | tail -5 && swift test 2>&1 | tail -10
```

Expected: `Build complete!` and all tests pass

- [ ] **Step 5: Commit**

```bash
git add Sources/RPPlayer/App/AppContainer.swift
git commit -m "feat(upcoming): wire UpcomingWindowController into AppContainer"
```

---

## Task 10: Full verification and final commit

- [ ] **Step 1: Run complete test suite**

```bash
swift test 2>&1 | tail -15
```

Expected: all tests pass (count should be ≥ 287 + new upcoming tests)

- [ ] **Step 2: Build the app**

```bash
swift build 2>&1 | tail -5
```

Expected: `Build complete!`

- [ ] **Step 3: Manual smoke test (if running the app locally)**

1. Launch the app
2. Click the menu bar icon to open the popover
3. Open the hamburger menu → "Upcoming Program…" → window opens
4. Skeleton appears briefly, then cards render with ambient gradients
5. ↻ button triggers a fresh fetch
6. Open Settings → Upcoming Program section shows row count stepper and channel toggles
7. Change row count to 3, reopen window → only 3 rows per column
8. Uncheck a channel, refresh → that column disappears

- [ ] **Step 4: Update CLAUDE.md PR table and test count**

In `CLAUDE.md`, update:
- PR 19 status to `✅ merged to main` (or keep `⬜ pending` until actually merged)
- Test count entry for after PR 19

- [ ] **Step 5: Final commit if anything was adjusted**

```bash
git add CLAUDE.md
git commit -m "docs: update CLAUDE.md for PR 19 — upcoming program window"
```

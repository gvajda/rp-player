# PR 1 — Foundation Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Land the project's foundation: a buildable Swift package with a test target, the missing scaffold docs (`docs/LEGACY.md`, root `README.md`, `LICENSE`), a logging facility (`AppLogger` + `RotatingFileSink`), and a JSON-backed settings store (`AppSettings` + `JSONConfigStore`).

**Architecture:** All modules sit behind protocols where downstream code will mock them. `JSONConfigStore` is an `actor` to serialize reads/writes; `RotatingFileSink` uses an internal serial `DispatchQueue` for synchronous log-write semantics. Settings live at `~/Library/Application Support/RP Player/config.json`; logs at `~/Library/Logs/RP Player/`. Both paths are computed by a single `ConfigPaths` enum so later modules don't recompute them.

**Tech Stack:** Swift (tools-version 6.2), macOS 13 minimum, Foundation, `os.Logger`, XCTest.

---

## File structure

**Created**

- `docs/LEGACY.md` — short pointer doc per `docs/DESIGN.md` §11.1.
- `README.md` (repo root) — brief project overview + build instructions.
- `LICENSE` (repo root) — standard MIT.
- `Sources/RPPlayer/Logging/RotatingFileSink.swift` — disk-rotating log file writer.
- `Sources/RPPlayer/Logging/AppLogger.swift` — `os.Logger` + sink wrapper, log levels.
- `Sources/RPPlayer/Config/AppSettings.swift` — Codable settings struct.
- `Sources/RPPlayer/Config/ConfigPaths.swift` — Application Support / Logs path helpers.
- `Sources/RPPlayer/Config/ConfigStore.swift` — `ConfigStore` protocol + `JSONConfigStore` actor.
- `Tests/RPPlayerTests/Logging/RotatingFileSinkTests.swift`
- `Tests/RPPlayerTests/Config/ConfigStoreTests.swift`

**Modified**

- `Package.swift` — add `platforms: [.macOS(.v13)]`, explicit `path:` on the executable target, add a test target.

**Untouched**

- `Sources/RPPlayer/RPPlayer.swift` — existing `@main` hello-world placeholder; replaced in PR 8 by the AppKit shell.

---

## Task 1: Update `Package.swift`

**Files:**

- - Modify: `Package.swift`
- [ ] **Step 1: Replace contents**

```swift
// swift-tools-version: 6.2
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
    name: "RPPlayer",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(
            name: "RPPlayer",
            path: "Sources/RPPlayer"
        ),
        .testTarget(
            name: "RPPlayerTests",
            dependencies: ["RPPlayer"],
            path: "Tests/RPPlayerTests"
        ),
    ]
)
```

- [ ] **Step 2: Verify the package still builds**

Run: `swift build` Expected: `Build complete!` with no errors. The placeholder `RPPlayer.swift` stays as-is.

- [ ] **Step 3: Verify the test target resolves (no tests yet)**

Run: `swift test` Expected: `Test Suite 'All tests' passed` with `Executed 0 tests`. (Test target compiles but is empty until Task 4.)

- [ ] **Step 4: Commit**

```bash
git add Package.swift
git commit -m "chore(pr01): set macOS 13 platform and add test target"
```

---

## Task 2: Author `docs/LEGACY.md`

**Files:**

- - Create: `docs/LEGACY.md`
- [ ] **Step 1: Write the file**

```markdown
# Legacy: RP_Notify (Windows)

This project supersedes [RP_Notify](https://github.com/gvajda/radio-paradise-song-notification), a Windows tray app that displayed Radio Paradise song notifications and accepted ratings.

## Scope diff

**Dropped from RP_Notify**

- Tracker mode (polling `api/nowplaying*` and `api/sync_v2` to follow external sessions).
- foobar2000 (`foo_beefweb`) integration.
- MusicBee (`MusicBeeIPC`) integration.

**Added in RP Player**

- In-app audio playback via libmpv.
- Bit-perfect output: CoreAudio hog mode + integer mode passthrough to a user-selected output device.
- Skip-forward within Radio Paradise's 4-song block API.

## Source of truth

[`DESIGN.md`](DESIGN.md) is the source of truth for the new project. The legacy code in [`legacy/`](legacy/) is reference material only — do not port the C# line-by-line.
```

- [ ] **Step 2: Commit**

```bash
git add docs/LEGACY.md
git commit -m "docs(pr01): add LEGACY.md scope-diff pointer"
```

---

## Task 3: Author root `README.md` and `LICENSE`

**Files:**

- - Create: `README.md`
- Create: `LICENSE`
- [ ] **Step 1: Write**`README.md`

````markdown
# RP Player

Bit-perfect Radio Paradise player for macOS — menu-bar app with desktop notifications and in-app song rating.

## Status

Pre-alpha. See [`docs/DESIGN.md`](docs/DESIGN.md) for the full design and locked decisions, and [`docs/LEGACY.md`](docs/LEGACY.md) for the relationship to the predecessor Windows app.

## Build

Requires Xcode 15+ on macOS 13+.

```sh
swift build
swift test
````

A local `libmpv.dylib` is required to run the player; setup instructions live at `Vendor/libmpv/README.md` (added in PR 5). Until then, `swift build` succeeds without it because no module links against libmpv yet.

## License

MIT — see `LICENSE`.

## History

This project supersedes the Windows tray app [RP\_Notify](https://github.com/gvajda/radio-paradise-song-notification). Scope diff in `docs/LEGACY.md`.

```

- [ ] **Step 2: Write `LICENSE` (standard MIT)**
```

MIT License

Copyright (c) 2026 Gergely Vajda

Permission is hereby granted, free of charge, to any person obtaining a copy of this software and associated documentation files (the "Software"), to deal in the Software without restriction, including without limitation the rights to use, copy, modify, merge, publish, distribute, sublicense, and/or sell copies of the Software, and to permit persons to whom the Software is furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.

````

- [ ] **Step 3: Commit**

```bash
git add README.md LICENSE
git commit -m "docs(pr01): add README and MIT LICENSE"
````

---

## Task 4: `RotatingFileSink` — failing test

**Files:**

- - Create: `Tests/RPPlayerTests/Logging/RotatingFileSinkTests.swift`
- [ ] **Step 1: Write the test file**

```swift
import XCTest
@testable import RPPlayer

final class RotatingFileSinkTests: XCTestCase {
    private func makeTempDir() -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("RPPlayerTests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    func testWritesToCurrentLog() throws {
        let dir = makeTempDir()
        let sink = try RotatingFileSink(
            directory: dir, baseName: "Test", fileExtension: "log",
            maxFileBytes: 1024, maxFiles: 3
        )
        sink.writeLine("hello")
        let url = dir.appendingPathComponent("Test.log")
        let contents = try String(contentsOf: url, encoding: .utf8)
        XCTAssertTrue(contents.contains("hello"))
    }

    func testRotatesWhenSizeExceeded() throws {
        let dir = makeTempDir()
        let sink = try RotatingFileSink(
            directory: dir, baseName: "Test", fileExtension: "log",
            maxFileBytes: 100, maxFiles: 3
        )
        let line = String(repeating: "x", count: 90)
        sink.writeLine(line)
        sink.writeLine(line)
        sink.writeLine(line)

        let fm = FileManager.default
        XCTAssertTrue(fm.fileExists(atPath: dir.appendingPathComponent("Test.log").path))
        XCTAssertTrue(fm.fileExists(atPath: dir.appendingPathComponent("Test.1.log").path))
    }

    func testDropsOldestBeyondMaxFiles() throws {
        let dir = makeTempDir()
        let sink = try RotatingFileSink(
            directory: dir, baseName: "Test", fileExtension: "log",
            maxFileBytes: 100, maxFiles: 2
        )
        let line = String(repeating: "x", count: 90)
        for _ in 0..<6 { sink.writeLine(line) }

        let fm = FileManager.default
        XCTAssertTrue(fm.fileExists(atPath: dir.appendingPathComponent("Test.log").path))
        XCTAssertTrue(fm.fileExists(atPath: dir.appendingPathComponent("Test.1.log").path))
        XCTAssertTrue(fm.fileExists(atPath: dir.appendingPathComponent("Test.2.log").path))
        XCTAssertFalse(fm.fileExists(atPath: dir.appendingPathComponent("Test.3.log").path))
    }
}
```

- [ ] **Step 2: Run the test to confirm it fails**

Run: `swift test --filter RotatingFileSinkTests` Expected: build fails with `cannot find 'RotatingFileSink' in scope`. (Compile-time failure counts as a failing test.)

---

## Task 5: `RotatingFileSink` — implementation

**Files:**

- - Create: `Sources/RPPlayer/Logging/RotatingFileSink.swift`
- [ ] **Step 1: Write the implementation**

```swift
import Foundation

/// Append-only log file with size-based rotation. `Base.log` is the active
/// file; on overflow it becomes `Base.1.log` and the previous `Base.N.log`
/// files shift down. `Base.<maxFiles>.log` is dropped when full.
public final class RotatingFileSink {
    private let directory: URL
    private let baseName: String
    private let fileExtension: String
    private let maxFileBytes: Int
    private let maxFiles: Int
    private let queue = DispatchQueue(label: "com.gvajda.RPPlayer.RotatingFileSink")
    private var handle: FileHandle?

    public init(
        directory: URL,
        baseName: String = "RPPlayer",
        fileExtension: String = "log",
        maxFileBytes: Int = 1_048_576,
        maxFiles: Int = 10
    ) throws {
        self.directory = directory
        self.baseName = baseName
        self.fileExtension = fileExtension
        self.maxFileBytes = maxFileBytes
        self.maxFiles = maxFiles
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true
        )
        try openHandle()
    }

    public func writeLine(_ line: String) {
        queue.sync {
            let payload = (line + "\n").data(using: .utf8) ?? Data()
            do {
                try rotateIfNeeded(adding: payload.count)
                handle?.write(payload)
            } catch {
                // Disk full / IO error must not crash the app.
            }
        }
    }

    deinit {
        try? handle?.close()
    }

    private var currentURL: URL {
        directory.appendingPathComponent("\(baseName).\(fileExtension)")
    }

    private func archivedURL(_ index: Int) -> URL {
        directory.appendingPathComponent("\(baseName).\(index).\(fileExtension)")
    }

    private func openHandle() throws {
        let url = currentURL
        if !FileManager.default.fileExists(atPath: url.path) {
            FileManager.default.createFile(atPath: url.path, contents: nil)
        }
        handle = try FileHandle(forWritingTo: url)
        try handle?.seekToEnd()
    }

    private func rotateIfNeeded(adding bytes: Int) throws {
        let url = currentURL
        let size = (try FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0
        if size + bytes <= maxFileBytes { return }

        try handle?.close()
        handle = nil

        let fm = FileManager.default
        let oldest = archivedURL(maxFiles)
        if fm.fileExists(atPath: oldest.path) {
            try fm.removeItem(at: oldest)
        }
        for i in stride(from: maxFiles - 1, through: 1, by: -1) {
            let from = archivedURL(i)
            let to = archivedURL(i + 1)
            if fm.fileExists(atPath: from.path) {
                try fm.moveItem(at: from, to: to)
            }
        }
        try fm.moveItem(at: url, to: archivedURL(1))
        try openHandle()
    }
}
```

- [ ] **Step 2: Run the tests and confirm they pass**

Run: `swift test --filter RotatingFileSinkTests` Expected: 3 tests pass.

- [ ] **Step 3: Commit**

```bash
git add Sources/RPPlayer/Logging/RotatingFileSink.swift Tests/RPPlayerTests/Logging/RotatingFileSinkTests.swift
git commit -m "feat(pr01): add RotatingFileSink with size-based rotation"
```

---

## Task 6: `AppLogger`

**Files:**

- Create: `Sources/RPPlayer/Logging/AppLogger.swift`

No dedicated tests: AppLogger is a thin pass-through over `os.Logger` and `RotatingFileSink`. The sink is covered in Task 5; `os.Logger` is Apple-tested. Wiring is exercised by the AppContainer build in PR 8.

- [ ] **Step 1: Write the file**

```swift
import Foundation
import os

public struct AppLogger: Sendable {
    public enum Level: String, Codable, Sendable, Comparable {
        case debug, info, warn, error

        private var rank: Int {
            switch self {
            case .debug: return 0
            case .info:  return 1
            case .warn:  return 2
            case .error: return 3
            }
        }

        public static func < (lhs: Level, rhs: Level) -> Bool { lhs.rank < rhs.rank }
    }

    public static let subsystem = "com.gvajda.RPPlayer"

    private let osLogger: os.Logger
    private let sink: RotatingFileSink?
    private let category: String
    private let minimumLevel: Level

    public init(category: String, sink: RotatingFileSink? = nil, minimumLevel: Level = .info) {
        self.osLogger = os.Logger(subsystem: Self.subsystem, category: category)
        self.sink = sink
        self.category = category
        self.minimumLevel = minimumLevel
    }

    public func debug(_ message: @autoclosure () -> String) { emit(.debug, message) }
    public func info(_ message: @autoclosure () -> String)  { emit(.info,  message) }
    public func warn(_ message: @autoclosure () -> String)  { emit(.warn,  message) }
    public func error(_ message: @autoclosure () -> String) { emit(.error, message) }

    private func emit(_ level: Level, _ message: () -> String) {
        guard level >= minimumLevel else { return }
        let text = message()
        switch level {
        case .debug: osLogger.debug("\(text, privacy: .public)")
        case .info:  osLogger.info("\(text, privacy: .public)")
        case .warn:  osLogger.warning("\(text, privacy: .public)")
        case .error: osLogger.error("\(text, privacy: .public)")
        }
        sink?.writeLine("\(Self.timestamp()) [\(level.rawValue.uppercased())] [\(category)] \(text)")
    }

    private static func timestamp() -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f.string(from: Date())
    }
}
```

- [ ] **Step 2: Verify it builds**

Run: `swift build` Expected: `Build complete!`

- [ ] **Step 3: Commit**

```bash
git add Sources/RPPlayer/Logging/AppLogger.swift
git commit -m "feat(pr01): add AppLogger wrapping os.Logger + RotatingFileSink"
```

---

## Task 7: `AppSettings` and `ConfigPaths`

**Files:**

- - Create: `Sources/RPPlayer/Config/AppSettings.swift`
- Create: `Sources/RPPlayer/Config/ConfigPaths.swift`
- [ ] **Step 1: Write**`AppSettings.swift`

```swift
import Foundation

public struct AppSettings: Codable, Equatable, Sendable {
    public var selectedChannelId: Int
    public var hogModeEnabled: Bool
    public var softwareVolumeEnabled: Bool
    public var notificationsEnabled: Bool
    public var bitrate: Int
    public var outputDeviceUID: String?
    public var logLevel: AppLogger.Level

    public init(
        selectedChannelId: Int = 0,
        hogModeEnabled: Bool = true,
        softwareVolumeEnabled: Bool = false,
        notificationsEnabled: Bool = true,
        bitrate: Int = 4,
        outputDeviceUID: String? = nil,
        logLevel: AppLogger.Level = .info
    ) {
        self.selectedChannelId = selectedChannelId
        self.hogModeEnabled = hogModeEnabled
        self.softwareVolumeEnabled = softwareVolumeEnabled
        self.notificationsEnabled = notificationsEnabled
        self.bitrate = bitrate
        self.outputDeviceUID = outputDeviceUID
        self.logLevel = logLevel
    }

    public static let `default` = AppSettings()
}
```

- [ ] **Step 2: Write**`ConfigPaths.swift`

```swift
import Foundation

public enum ConfigPaths {
    public static var applicationSupportRoot: URL {
        let base = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask
        ).first!
        return base.appendingPathComponent("RP Player", isDirectory: true)
    }

    public static var configFile: URL {
        applicationSupportRoot.appendingPathComponent("config.json")
    }

    public static var albumArtCacheDirectory: URL {
        applicationSupportRoot.appendingPathComponent("AlbumArtCache", isDirectory: true)
    }

    public static var logsDirectory: URL {
        let base = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask).first!
        return base
            .appendingPathComponent("Logs", isDirectory: true)
            .appendingPathComponent("RP Player", isDirectory: true)
    }
}
```

- [ ] **Step 3: Verify build**

Run: `swift build` Expected: `Build complete!`

- [ ] **Step 4: Commit**

```bash
git add Sources/RPPlayer/Config/AppSettings.swift Sources/RPPlayer/Config/ConfigPaths.swift
git commit -m "feat(pr01): add AppSettings struct and ConfigPaths helper"
```

---

## Task 8: `ConfigStore` — failing test

**Files:**

- - Create: `Tests/RPPlayerTests/Config/ConfigStoreTests.swift`
- [ ] **Step 1: Write the test file**

```swift
import XCTest
@testable import RPPlayer

final class ConfigStoreTests: XCTestCase {
    private func makeTempURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("RPPlayerTests-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent("config.json")
    }

    func testLoadsDefaultsWhenFileMissing() async throws {
        let url = makeTempURL()
        let store = try JSONConfigStore(url: url)
        let s = await store.settings
        XCTAssertEqual(s, .default)
    }

    func testRoundTripAcrossInstances() async throws {
        let url = makeTempURL()
        let store1 = try JSONConfigStore(url: url)
        try await store1.update {
            $0.selectedChannelId = 5
            $0.hogModeEnabled = false
        }

        let store2 = try JSONConfigStore(url: url)
        let s = await store2.settings
        XCTAssertEqual(s.selectedChannelId, 5)
        XCTAssertFalse(s.hogModeEnabled)
    }

    func testUpdateEmitsChange() async throws {
        let url = makeTempURL()
        let store = try JSONConfigStore(url: url)
        let stream = await store.changes
        let received = Task { () -> AppSettings? in
            for await s in stream {
                if s.selectedChannelId == 7 { return s }
            }
            return nil
        }
        try await store.update { $0.selectedChannelId = 7 }
        let result = await received.value
        XCTAssertEqual(result?.selectedChannelId, 7)
    }

    func testNoOpUpdateDoesNotEmit() async throws {
        let url = makeTempURL()
        let store = try JSONConfigStore(url: url)
        try await store.update { $0.selectedChannelId = 5 }

        let stream = await store.changes
        let collector = Task { () -> [Int] in
            var ids: [Int] = []
            for await s in stream {
                ids.append(s.selectedChannelId)
                if ids.count == 2 { return ids }
            }
            return ids
        }
        try await store.update { $0.selectedChannelId = 5 } // no-op
        try await store.update { $0.selectedChannelId = 6 } // change
        let ids = await collector.value
        // First emission is the current snapshot (5); second is the real change (6).
        XCTAssertEqual(ids, [5, 6])
    }
}
```

- [ ] **Step 2: Run tests to confirm they fail**

Run: `swift test --filter ConfigStoreTests` Expected: build fails with `cannot find 'JSONConfigStore' in scope`.

---

## Task 9: `ConfigStore` — implementation

**Files:**

- - Create: `Sources/RPPlayer/Config/ConfigStore.swift`
- [ ] **Step 1: Write the file**

```swift
import Foundation

/// Persistent, concurrency-safe settings store. Backed by JSON on disk; mock-able in tests via the protocol.
public protocol ConfigStore: Sendable, AnyObject {
    var settings: AppSettings { get async }
    var changes: AsyncStream<AppSettings> { get async }
    func update(_ mutate: @Sendable (inout AppSettings) -> Void) async throws
}

public actor JSONConfigStore: ConfigStore {
    public let url: URL
    private var current: AppSettings
    private var continuations: [UUID: AsyncStream<AppSettings>.Continuation] = [:]

    public init(url: URL) throws {
        self.url = url
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        if let data = try? Data(contentsOf: url),
           let loaded = try? JSONDecoder().decode(AppSettings.self, from: data) {
            self.current = loaded
        } else {
            self.current = .default
            // Best-effort initial write; in-memory defaults remain valid if disk write fails.
            try? Self.write(.default, to: url)
        }
    }

    public var settings: AppSettings { current }

    /// Subscribes a new continuation atomically: by the time the stream is returned,
    /// the subscriber is registered and has been yielded the current snapshot.
    /// Subsequent `update` calls on this actor are guaranteed to be observed.
    public var changes: AsyncStream<AppSettings> {
        let id = UUID()
        return AsyncStream { continuation in
            self.continuations[id] = continuation
            continuation.yield(self.current)
            continuation.onTermination = { [weak self] _ in
                Task { [weak self] in await self?.unregister(id: id) }
            }
        }
    }

    public func update(_ mutate: @Sendable (inout AppSettings) -> Void) async throws {
        var copy = current
        mutate(&copy)
        guard copy != current else { return }
        try Self.write(copy, to: url)
        current = copy
        for c in continuations.values {
            c.yield(copy)
        }
    }

    private func unregister(id: UUID) {
        continuations.removeValue(forKey: id)
    }

    private static func write(_ settings: AppSettings, to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(settings)
        try data.write(to: url, options: [.atomic])
    }
}
```

> **Deviation note (approved):** `changes` was changed from `nonisolated` synchronous to `async` actor-isolated, eliminating two registration race conditions flagged in code review. Registration now happens atomically on the actor before the stream is returned; `Task.sleep` bridges in tests are no longer needed.

- [ ] **Step 2: Run tests and confirm they pass**

Run: `swift test --filter ConfigStoreTests` Expected: 4 tests pass.

- [ ] **Step 3: Commit**

```bash
git add Sources/RPPlayer/Config/ConfigStore.swift Tests/RPPlayerTests/Config/ConfigStoreTests.swift
git commit -m "feat(pr01): add ConfigStore protocol and JSONConfigStore actor"
```

---

## Task 10: Final verification

- [ ] **Step 1: Build clean**

Run: `swift build -c release` Expected: `Build complete!` with no warnings related to the new modules.

- [ ] **Step 2: Run all tests**

Run: `swift test` Expected: 7 tests pass (3 RotatingFileSink + 4 ConfigStore), 0 failures.

- [ ] **Step 3: Verify on-disk artifacts**

Run: `swift run RPPlayer` Expected: prints `Hello, world!` and exits cleanly. (Behavior unchanged from the scaffold; PR 8 replaces this entry point.)

- [ ] **Step 4: Confirm git tree is clean**

Run: `git status` Expected: `nothing to commit, working tree clean`.

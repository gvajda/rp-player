# PR 7 — AppKit Shell Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the hello-world entry point with a real menu-bar shell — `NSStatusItem` in the system menu bar that toggles an `NSPopover` hosting a SwiftUI placeholder view. PR 8 fills the popover with `MiniPlayerView`; this PR only lands the scaffolding.

**Architecture:** A minimal `@main` struct boots `NSApplication` with `.accessory` activation policy (no Dock icon, no main menu). An `AppDelegate` (NSApplicationDelegate) instantiates a `StatusItemController` on `applicationDidFinishLaunching`. `StatusItemController` owns the `NSStatusItem` (variable-length, SF-Symbol icon) and a `PopoverController` that owns an `NSPopover` whose content view controller is an `NSHostingController` wrapping `AppShellPlaceholderView`. Click on the status-bar button toggles the popover. Behavior is `.transient` so the popover dismisses on outside click. No coordinator wiring yet — PR 11 (`AppContainer`) injects real dependencies into the shell.

**Tech Stack:** Swift 6.2, AppKit (`NSStatusBar`, `NSStatusItem`, `NSPopover`, `NSHostingController`), SwiftUI for view content, XCTest.

---

## File structure

**Created**

- `Sources/RPPlayer/Shell/AppShellPlaceholderView.swift` — SwiftUI placeholder view (320×420, "RP Player" + scaffold note).
- `Sources/RPPlayer/Shell/PopoverController.swift` — `@MainActor` class wrapping `NSPopover`; configures content size, behavior, and `NSHostingController` content.
- `Sources/RPPlayer/Shell/StatusItemController.swift` — `@MainActor` class wrapping `NSStatusItem`; sets icon, tooltip, click action; toggles popover via `PopoverController`.
- `Sources/RPPlayer/Shell/AppDelegate.swift` — `NSApplicationDelegate` that creates the `StatusItemController` on launch and retains it for the app's lifetime.
- `Tests/RPPlayerTests/Shell/AppShellPlaceholderViewTests.swift`
- `Tests/RPPlayerTests/Shell/PopoverControllerTests.swift`
- `Tests/RPPlayerTests/Shell/StatusItemControllerTests.swift`

**Modified**

- `Sources/RPPlayer/RPPlayer.swift` — replace hello-world with `NSApplication.shared.run()` boot wired to `AppDelegate`.
- `CLAUDE.md` — flip PR 7 to ✅ at the end, bump test count, add a key-decisions entry for the activation policy choice.

**Untouched**

- All PR 1–6 modules (`Logging/`, `Config/`, `Api/`, `Auth/`, `Player/`, `Playback/`).

---

## Conventions used by this PR

- **Activation policy:** `.accessory`. The app is a menu-bar utility — no Dock icon, no Cmd-Tab presence, no main menu bar takeover. Set at runtime via `NSApp.setActivationPolicy(.accessory)` since SPM executables ship without an `Info.plist` (PR 12 will introduce the real `.app` bundle and may move this into `LSUIElement`).
- **No abstractions yet:** controllers are concrete `@MainActor` classes. PR 11 (`AppContainer`) is the right place to introduce protocols if real dependencies need to be mocked. Per CLAUDE.md, don't add abstractions beyond current need.
- **Hosting:** SwiftUI is hosted via `NSHostingController(rootView:)`. The popover sets `contentViewController`, so the host controller's view is sized by `popover.contentSize`.
- **Status item icon:** SF Symbol `music.note`, `.template` rendering so the menu bar applies the system tint. Tooltip `"RP Player"`. Variable length so a future state-pill (e.g. ⏸) can replace it without re-laying out.
- **Headless test caveat:** `NSStatusBar.system.statusItem(withLength:)` works in `swift test` on macOS as long as the test process has a window-server connection (the default for local `swift test`). Tests construct a real `NSStatusItem` and inspect properties; they do **not** call `popover.show(relativeTo:...)` because that requires a real on-screen anchor view. Toggle logic is tested via direct method calls and `popover.isShown` plus an injectable "show / close" abstraction described in Task 3.

---

## Task 1: SwiftUI placeholder view

**Files:**
- Create: `Sources/RPPlayer/Shell/AppShellPlaceholderView.swift`
- Create: `Tests/RPPlayerTests/Shell/AppShellPlaceholderViewTests.swift`

- [ ] **Step 1: Write failing test**

```swift
import SwiftUI
import XCTest
@testable import RPPlayer

@MainActor
final class AppShellPlaceholderViewTests: XCTestCase {
    func testHostingControllerExposesPlaceholderViewWithoutCrash() {
        let host = NSHostingController(rootView: AppShellPlaceholderView())
        host.loadView()
        XCTAssertNotNil(host.view)
        XCTAssertGreaterThan(host.view.intrinsicContentSize.width, 0)
    }

    func testPlaceholderHeadlineIsRpPlayer() {
        XCTAssertEqual(AppShellPlaceholderView.headline, "RP Player")
    }
}
```

- [ ] **Step 2: Run — expect failure**

Run: `swift test --filter RPPlayerTests.AppShellPlaceholderViewTests`
Expected: compile error / unresolved identifier `AppShellPlaceholderView`.

- [ ] **Step 3: Implement the view**

```swift
import SwiftUI

struct AppShellPlaceholderView: View {
    static let headline = "RP Player"
    static let subhead = "Menu-bar shell scaffold — playback UI lands in PR 8."

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "music.note")
                .font(.system(size: 48, weight: .regular))
                .foregroundStyle(.secondary)
            Text(Self.headline)
                .font(.title2)
                .fontWeight(.semibold)
            Text(Self.subhead)
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 24)
        }
        .frame(width: 320, height: 420)
        .padding()
    }
}
```

- [ ] **Step 4: Run — expect pass**

Run: `swift test --filter RPPlayerTests.AppShellPlaceholderViewTests`
Expected: 2 tests pass.

- [ ] **Step 5: Commit**

```bash
git add Sources/RPPlayer/Shell/AppShellPlaceholderView.swift \
        Tests/RPPlayerTests/Shell/AppShellPlaceholderViewTests.swift
git commit -m "feat(pr07): AppShellPlaceholderView for the menu-bar popover"
```

---

## Task 2: PopoverController

**Files:**
- Create: `Sources/RPPlayer/Shell/PopoverController.swift`
- Create: `Tests/RPPlayerTests/Shell/PopoverControllerTests.swift`

- [ ] **Step 1: Write failing test**

```swift
import AppKit
import SwiftUI
import XCTest
@testable import RPPlayer

@MainActor
final class PopoverControllerTests: XCTestCase {
    func testInitConfiguresPopoverContentSizeAndBehavior() {
        let controller = PopoverController()
        XCTAssertEqual(controller.popover.contentSize, NSSize(width: 320, height: 420))
        XCTAssertEqual(controller.popover.behavior, .transient)
        XCTAssertTrue(controller.popover.contentViewController is NSHostingController<AppShellPlaceholderView>)
    }

    func testIsShownReflectsPopoverState() {
        let controller = PopoverController()
        XCTAssertFalse(controller.isShown)
        // Driving show()/close() requires a live anchor view; covered indirectly
        // by StatusItemController tests via injected hooks.
    }
}
```

- [ ] **Step 2: Run — expect failure**

Run: `swift test --filter RPPlayerTests.PopoverControllerTests`
Expected: compile error — `PopoverController` undefined.

- [ ] **Step 3: Implement**

```swift
import AppKit
import SwiftUI

@MainActor
final class PopoverController {
    let popover: NSPopover

    init() {
        let popover = NSPopover()
        popover.contentSize = NSSize(width: 320, height: 420)
        popover.behavior = .transient
        popover.contentViewController = NSHostingController(rootView: AppShellPlaceholderView())
        self.popover = popover
    }

    var isShown: Bool { popover.isShown }

    func show(relativeTo anchor: NSView) {
        popover.show(relativeTo: anchor.bounds, of: anchor, preferredEdge: .minY)
    }

    func close() {
        popover.performClose(nil)
    }
}
```

- [ ] **Step 4: Run — expect pass**

Run: `swift test --filter RPPlayerTests.PopoverControllerTests`
Expected: 2 tests pass.

- [ ] **Step 5: Commit**

```bash
git add Sources/RPPlayer/Shell/PopoverController.swift \
        Tests/RPPlayerTests/Shell/PopoverControllerTests.swift
git commit -m "feat(pr07): PopoverController hosting AppShellPlaceholderView"
```

---

## Task 3: StatusItemController

**Files:**
- Create: `Sources/RPPlayer/Shell/StatusItemController.swift`
- Create: `Tests/RPPlayerTests/Shell/StatusItemControllerTests.swift`

The popover toggle logic is the unit under test. To avoid calling `popover.show(relativeTo:...)` (which needs an on-screen anchor in headless XCTest), `StatusItemController` exposes a `toggle()` entry point that delegates the show/close decision to two injected closures defaulting to the real popover calls. Tests inject counting stubs.

- [ ] **Step 1: Write failing test**

```swift
import AppKit
import XCTest
@testable import RPPlayer

@MainActor
final class StatusItemControllerTests: XCTestCase {
    private var popoverController: PopoverController!
    private var showCount = 0
    private var closeCount = 0

    override func setUp() async throws {
        popoverController = PopoverController()
        showCount = 0
        closeCount = 0
    }

    private func makeController() -> StatusItemController {
        StatusItemController(
            popover: popoverController,
            show: { [unowned self] _ in self.showCount += 1 },
            close: { [unowned self] in self.closeCount += 1 }
        )
    }

    func testButtonImageAndTooltipAreConfigured() {
        let controller = makeController()
        let button = controller.statusItem.button
        XCTAssertNotNil(button)
        XCTAssertEqual(button?.toolTip, "RP Player")
        XCTAssertNotNil(button?.image)
        XCTAssertTrue(button?.image?.isTemplate ?? false)
    }

    func testToggleShowsWhenPopoverIsHidden() {
        let controller = makeController()
        controller.toggle()
        XCTAssertEqual(showCount, 1)
        XCTAssertEqual(closeCount, 0)
    }

    func testToggleClosesWhenPopoverIsShown() {
        final class AlwaysShownPopover: PopoverController {
            override var isShown: Bool { true }
        }
        let stub = AlwaysShownPopover()
        let controller = StatusItemController(
            popover: stub,
            show: { [unowned self] _ in self.showCount += 1 },
            close: { [unowned self] in self.closeCount += 1 }
        )
        controller.toggle()
        XCTAssertEqual(showCount, 0)
        XCTAssertEqual(closeCount, 1)
    }
}
```

- [ ] **Step 2: Run — expect failure**

Run: `swift test --filter RPPlayerTests.StatusItemControllerTests`
Expected: compile errors — `StatusItemController` and the injectable hooks do not exist; `PopoverController.isShown` is not `open`.

- [ ] **Step 3: Make `PopoverController` subclassable for tests**

Edit `Sources/RPPlayer/Shell/PopoverController.swift`:

```swift
import AppKit
import SwiftUI

@MainActor
class PopoverController {
    let popover: NSPopover

    init() {
        let popover = NSPopover()
        popover.contentSize = NSSize(width: 320, height: 420)
        popover.behavior = .transient
        popover.contentViewController = NSHostingController(rootView: AppShellPlaceholderView())
        self.popover = popover
    }

    var isShown: Bool { popover.isShown }

    func show(relativeTo anchor: NSView) {
        popover.show(relativeTo: anchor.bounds, of: anchor, preferredEdge: .minY)
    }

    func close() {
        popover.performClose(nil)
    }
}
```

The diff vs Task 2 is `final class` → `class` and `var isShown` becomes overridable. Re-run the Task 2 tests to confirm they still pass:

Run: `swift test --filter RPPlayerTests.PopoverControllerTests`
Expected: still 2 tests pass.

- [ ] **Step 4: Implement `StatusItemController`**

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

- [ ] **Step 5: Run — expect pass**

Run: `swift test --filter RPPlayerTests.StatusItemControllerTests`
Expected: 3 tests pass.

- [ ] **Step 6: Run the full suite to confirm no regression**

Run: `swift test`
Expected: every test passes; total = previous + 7 new (2 view + 2 popover + 3 status item).

- [ ] **Step 7: Commit**

```bash
git add Sources/RPPlayer/Shell/StatusItemController.swift \
        Sources/RPPlayer/Shell/PopoverController.swift \
        Tests/RPPlayerTests/Shell/StatusItemControllerTests.swift
git commit -m "feat(pr07): StatusItemController toggling popover via injectable hooks"
```

---

## Task 4: AppDelegate

**Files:**
- Create: `Sources/RPPlayer/Shell/AppDelegate.swift`
- Create: `Tests/RPPlayerTests/Shell/AppDelegateTests.swift`

- [ ] **Step 1: Write failing test**

```swift
import AppKit
import XCTest
@testable import RPPlayer

@MainActor
final class AppDelegateTests: XCTestCase {
    func testApplicationDidFinishLaunchingCreatesStatusItemController() {
        let delegate = AppDelegate()
        XCTAssertNil(delegate.statusItemController)
        delegate.applicationDidFinishLaunching(Notification(name: NSApplication.didFinishLaunchingNotification))
        XCTAssertNotNil(delegate.statusItemController)
    }
}
```

- [ ] **Step 2: Run — expect failure**

Run: `swift test --filter RPPlayerTests.AppDelegateTests`
Expected: `AppDelegate` undefined.

- [ ] **Step 3: Implement**

```swift
import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private(set) var statusItemController: StatusItemController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let popover = PopoverController()
        statusItemController = StatusItemController(popover: popover)
    }
}
```

- [ ] **Step 4: Run — expect pass**

Run: `swift test --filter RPPlayerTests.AppDelegateTests`
Expected: 1 test passes.

- [ ] **Step 5: Commit**

```bash
git add Sources/RPPlayer/Shell/AppDelegate.swift \
        Tests/RPPlayerTests/Shell/AppDelegateTests.swift
git commit -m "feat(pr07): AppDelegate boots StatusItemController on launch"
```

---

## Task 5: Replace `RPPlayer.swift` entry point

**Files:**
- Modify: `Sources/RPPlayer/RPPlayer.swift`

The new entry point starts `NSApplication`, sets `.accessory` activation policy, installs the delegate, and calls `run()`. There is no clean unit test for `@main` itself (it would block the test process in `NSApp.run()`); coverage is provided by `AppDelegateTests` plus the manual smoke step at the end of this task.

- [ ] **Step 1: Replace the file**

```swift
import AppKit

@main
enum RPPlayer {
    static func main() {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        let delegate = AppDelegate()
        app.delegate = delegate
        app.run()
    }
}
```

The previous `struct RPPlayer { static func main() { print("Hello, world!") } }` is fully replaced.

- [ ] **Step 2: Build**

Run: `swift build`
Expected: `Build complete!` with no warnings.

- [ ] **Step 3: Manual smoke — confirm the menu-bar icon appears**

Run: `swift run RPPlayer`

Expected: a `music.note` icon appears in the macOS menu bar. Clicking it opens a popover containing "RP Player" + the placeholder text. Clicking outside the popover dismisses it. Clicking the icon again toggles it. No Dock icon. No app menu in the system menu bar.

Press `Ctrl-C` in the terminal to quit. (`Cmd-Q` does nothing — there is no main menu yet; PR 11 wires that up alongside the real `AppContainer`.)

If the icon does not appear, check `NSApp.setActivationPolicy(.accessory)` is being called and that `applicationDidFinishLaunching` actually runs. Use `Console.app` filtered on `RPPlayer` to see logs.

- [ ] **Step 4: Run the full test suite**

Run: `swift test`
Expected: every test passes. Total = previous + 8 (2 view + 2 popover + 3 status item + 1 delegate). Record the new total for Task 7 below.

- [ ] **Step 5: Commit**

```bash
git add Sources/RPPlayer/RPPlayer.swift
git commit -m "feat(pr07): NSApplication entry point with .accessory activation"
```

---

## Task 6: Polish pass

**Files:**
- Modify: any of the four shell files if review surfaces issues.

- [ ] **Step 1: Review the shell module against `CLAUDE.md`**

Confirm:
- No multi-line comments. Only single `//` lines, and only where WHY is non-obvious.
- All shell types are `@MainActor` (every NSStatusItem / NSPopover / NSHostingController call must run on main).
- No dead code paths (every closure / property is reached by tests or by the entry point).
- Status item button uses a template SF Symbol (so dark/light menu-bar themes both render).

- [ ] **Step 2: Confirm `swift build` is clean**

Run: `swift build 2>&1 | grep -E '^(warning|error):' | head`
Expected: no output.

- [ ] **Step 3: Confirm `swift test` parallel run passes**

Run: `swift test --parallel`
Expected: every test passes.

- [ ] **Step 4: Commit polish (only if anything changed)**

```bash
git add Sources/RPPlayer/Shell
git commit -m "polish(pr07): comment audit and main-actor confirmation"
```

If nothing changed, skip the commit.

---

## Task 7: Update `CLAUDE.md`

**Files:**
- Modify: `CLAUDE.md`

- [ ] **Step 1: Flip PR 7 row to merged**

In the PR status table, change the PR 7 row to:

```markdown
| 7 | merged to main | ✅ | AppKit shell (NSStatusItem + NSPopover hosting placeholder) |
```

…and change the PR 8 row's status from `pending` / blank to `next`:

```markdown
| 8 | **next** | ⬜ | MiniPlayerView (SwiftUI) |
```

- [ ] **Step 2: Add new test count**

In the "Test counts by PR" section, append:

```markdown
- After PR 7: <new total> tests
```

Use the count from Task 5 Step 4. The expected delta is +8.

- [ ] **Step 3: Add a key-decisions entry for the activation policy**

Append under "Key technical decisions (non-obvious, not in code)":

```markdown
- The shell uses `NSApp.setActivationPolicy(.accessory)` set at runtime (not `LSUIElement` in an Info.plist) because SPM executable targets do not ship an Info.plist. PR 12 introduces the real `.app` bundle and may move this into `LSUIElement` for marginally faster startup; until then the runtime call is the only way to suppress the Dock icon.
- `PopoverController` is a non-`final` class (not a struct) only so tests can override `isShown`. The shell otherwise has no protocol abstractions — PR 11 (`AppContainer`) is the right place to introduce them if real dependencies need to be mocked.
```

- [ ] **Step 4: Commit**

```bash
git add CLAUDE.md
git commit -m "docs(pr07): record AppKit-shell decisions and post-PR7 test count"
```

- [ ] **Step 5: Fast-forward merge to `main`**

From the worktree root:

```bash
git checkout main
git merge --ff-only -
git checkout -
```

If the merge is not fast-forward, STOP. The branch must be at `main + N commits` for the project's locked merge strategy. Inspect with `git log --oneline main..HEAD`.

Confirm:

```bash
git rev-list --count main..HEAD
```

Expected: `0`.

---

## Self-review checklist

After executing all tasks, verify:

- **Spec coverage:** every PR 7 item from `CLAUDE.md` ("AppKit shell — NSStatusItem + NSPopover") is implemented or explicitly deferred to PR 8/11. ✅ All scaffolded.
- **Comment policy:** every new file is comment-free except where WHY is non-obvious; spot-check before final commit.
- **Comment policy in entry point:** `RPPlayer.swift` is comment-free.
- **Test count math:** previous = 93, expected new = 101 (93 + 2 view + 2 popover + 3 status item + 1 delegate). Adjust the `CLAUDE.md` entry to match the actual count if any test was inlined or merged.
- **No new abstractions:** no protocols introduced for shell components. PR 11's `AppContainer` will introduce them if needed.
- **No regression:** `swift build` clean, `swift test` 100% pass.

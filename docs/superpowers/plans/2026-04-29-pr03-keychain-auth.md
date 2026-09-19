# PR 3: KeychainAuth + Login Window Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a Keychain-backed `CookieProvider` and a `WKWebView`-based login window so users can authenticate with Radio Paradise without their password touching our process.

**Architecture:** `KeychainStore` protocol abstracts the Security framework; `SecItemKeychainStore` is the real implementation and `InMemoryKeychainStore` (test-only) is the test double. `KeychainCookieProvider` is a Swift actor conforming to `KeychainAuth: CookieProvider` — it stores and retrieves the session cookie from the Keychain. `LoginWindowController` (`@MainActor NSWindowController` + `WKWebView`) opens the RP sign-in page, observes cookies via `WKHTTPCookieStoreObserver`, extracts the three relevant cookies into a `Cookie:` header string using a pure `rpCookieString(from:)` helper, then stores the result via `KeychainAuth` and closes.

**Tech Stack:** Swift 6.2, Security framework, WebKit, AppKit, XCTest

---

## File map

**New source files:**
- `Sources/RPPlayer/Auth/KeychainStore.swift` — `KeychainStore` protocol, `KeychainError`, `SecItemKeychainStore`
- `Sources/RPPlayer/Auth/KeychainCookieProvider.swift` — `KeychainAuth` protocol, `KeychainCookieProvider` actor
- `Sources/RPPlayer/Auth/LoginWindow.swift` — `LoginWindowController` + pure `rpCookieString(from:)` static helper

**New test files:**
- `Tests/RPPlayerTests/Auth/InMemoryKeychainStore.swift` — `InMemoryKeychainStore` test double
- `Tests/RPPlayerTests/Auth/KeychainStoreTests.swift` — `SecItemKeychainStore` integration tests (real keychain, unique service, cleaned up in setUp/tearDown)
- `Tests/RPPlayerTests/Auth/KeychainCookieProviderTests.swift` — unit tests via `InMemoryKeychainStore`
- `Tests/RPPlayerTests/Auth/LoginWindowCookieExtractionTests.swift` — unit tests for `rpCookieString(from:)`

**Modified:**
- `Sources/RPPlayer/Api/CookieProvider.swift` — remove "PR 2 placeholder" doc comment from `AnonymousCookieProvider`

---

## Task 1: KeychainStore protocol + SecItemKeychainStore + InMemoryKeychainStore test double

**Files:**
- Create: `Tests/RPPlayerTests/Auth/KeychainStoreTests.swift`
- Create: `Sources/RPPlayer/Auth/KeychainStore.swift`
- Create: `Tests/RPPlayerTests/Auth/InMemoryKeychainStore.swift`

- [ ] **Step 1: Write the failing test**

Create `Tests/RPPlayerTests/Auth/KeychainStoreTests.swift`:

```swift
import XCTest
@testable import RPPlayer

final class KeychainStoreTests: XCTestCase {
    private let sut = SecItemKeychainStore()
    private let service = "com.gvajda.RPPlayer.tests"
    private let account = "test-cookie"

    override func setUp() async throws {
        try sut.delete(service: service, account: account)
    }

    override func tearDown() async throws {
        try sut.delete(service: service, account: account)
    }

    func testSaveAndLoad() throws {
        try sut.save(value: "C_username=foo", service: service, account: account)
        let loaded = try sut.load(service: service, account: account)
        XCTAssertEqual(loaded, "C_username=foo")
    }

    func testLoadReturnsNilWhenNotFound() throws {
        let loaded = try sut.load(service: service, account: account)
        XCTAssertNil(loaded)
    }

    func testDeleteRemovesItem() throws {
        try sut.save(value: "C_username=foo", service: service, account: account)
        try sut.delete(service: service, account: account)
        let loaded = try sut.load(service: service, account: account)
        XCTAssertNil(loaded)
    }

    func testDeleteIsIdempotent() throws {
        // Must not throw when item does not exist.
        XCTAssertNoThrow(try sut.delete(service: service, account: account))
    }

    func testSaveOverwritesExisting() throws {
        try sut.save(value: "C_username=old", service: service, account: account)
        try sut.save(value: "C_username=new", service: service, account: account)
        let loaded = try sut.load(service: service, account: account)
        XCTAssertEqual(loaded, "C_username=new")
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

```
swift test --filter KeychainStoreTests 2>&1 | head -20
```

Expected: compile error containing `cannot find type 'SecItemKeychainStore'`

- [ ] **Step 3: Implement KeychainStore.swift**

Create `Sources/RPPlayer/Auth/KeychainStore.swift`:

```swift
import Foundation
import Security

public enum KeychainError: Error, Sendable {
    case unexpectedStatus(OSStatus)
    case unexpectedData
}

public protocol KeychainStore: Sendable {
    func load(service: String, account: String) throws -> String?
    func save(value: String, service: String, account: String) throws
    func delete(service: String, account: String) throws
}

public struct SecItemKeychainStore: KeychainStore {
    public init() {}

    public func load(service: String, account: String) throws -> String? {
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: account,
            kSecReturnData: true,
            kSecMatchLimit: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw KeychainError.unexpectedStatus(status) }
        guard let data = item as? Data, let value = String(data: data, encoding: .utf8) else {
            throw KeychainError.unexpectedData
        }
        return value
    }

    public func save(value: String, service: String, account: String) throws {
        guard let data = value.data(using: .utf8) else { throw KeychainError.unexpectedData }
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: account,
        ]
        // Attempt update first; if not found, add.
        let updateStatus = SecItemUpdate(query as CFDictionary, [kSecValueData: data] as CFDictionary)
        if updateStatus == errSecItemNotFound {
            var addQuery = query
            addQuery[kSecValueData] = data
            let addStatus = SecItemAdd(addQuery as CFDictionary, nil)
            guard addStatus == errSecSuccess else { throw KeychainError.unexpectedStatus(addStatus) }
        } else if updateStatus != errSecSuccess {
            throw KeychainError.unexpectedStatus(updateStatus)
        }
    }

    public func delete(service: String, account: String) throws {
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: account,
        ]
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainError.unexpectedStatus(status)
        }
    }
}
```

- [ ] **Step 4: Create the InMemoryKeychainStore test double**

Create `Tests/RPPlayerTests/Auth/InMemoryKeychainStore.swift`:

```swift
@testable import RPPlayer

/// Dictionary-backed KeychainStore for tests. Thread-safety provided by
/// the actor isolation of KeychainCookieProvider — not needed here itself.
final class InMemoryKeychainStore: KeychainStore, @unchecked Sendable {
    private var storage: [String: String] = [:]

    func load(service: String, account: String) throws -> String? {
        storage["\(service):\(account)"]
    }

    func save(value: String, service: String, account: String) throws {
        storage["\(service):\(account)"] = value
    }

    func delete(service: String, account: String) throws {
        storage.removeValue(forKey: "\(service):\(account)")
    }
}
```

- [ ] **Step 5: Run tests to verify they pass**

```
swift test --filter KeychainStoreTests 2>&1 | tail -10
```

Expected: `Executed 5 tests, with 0 failures`

- [ ] **Step 6: Commit**

```bash
git add Sources/RPPlayer/Auth/KeychainStore.swift \
        Tests/RPPlayerTests/Auth/InMemoryKeychainStore.swift \
        Tests/RPPlayerTests/Auth/KeychainStoreTests.swift
git commit -m "feat(pr03): add KeychainStore protocol, SecItemKeychainStore, and test double"
```

---

## Task 2: KeychainAuth protocol + KeychainCookieProvider actor

**Files:**
- Create: `Tests/RPPlayerTests/Auth/KeychainCookieProviderTests.swift`
- Create: `Sources/RPPlayer/Auth/KeychainCookieProvider.swift`

- [ ] **Step 1: Write the failing test**

Create `Tests/RPPlayerTests/Auth/KeychainCookieProviderTests.swift`:

```swift
import XCTest
@testable import RPPlayer

final class KeychainCookieProviderTests: XCTestCase {
    private var keychainStore: InMemoryKeychainStore!
    private var sut: KeychainCookieProvider!

    override func setUp() {
        keychainStore = InMemoryKeychainStore()
        sut = KeychainCookieProvider(keychainStore: keychainStore)
    }

    func testCurrentCookieIsNilWhenNothingStored() async {
        let cookie = await sut.currentCookie()
        XCTAssertNil(cookie)
    }

    func testCurrentCookieReturnsStoredValue() async throws {
        try await sut.storeCookie("C_username=foo; C_passwd=hash; C_validated=tok")
        let cookie = await sut.currentCookie()
        XCTAssertEqual(cookie, "C_username=foo; C_passwd=hash; C_validated=tok")
    }

    func testIsLoggedInFalseWhenNoCookieStored() async {
        let loggedIn = await sut.isLoggedIn
        XCTAssertFalse(loggedIn)
    }

    func testIsLoggedInTrueAfterStoringCookie() async throws {
        try await sut.storeCookie("C_username=foo; C_passwd=hash; C_validated=tok")
        let loggedIn = await sut.isLoggedIn
        XCTAssertTrue(loggedIn)
    }

    func testClearCookieNilsCurrentCookie() async throws {
        try await sut.storeCookie("C_username=foo; C_passwd=hash; C_validated=tok")
        await sut.clearCookie()
        let cookie = await sut.currentCookie()
        XCTAssertNil(cookie)
    }

    func testIsLoggedInFalseAfterClearCookie() async throws {
        try await sut.storeCookie("C_username=foo; C_passwd=hash; C_validated=tok")
        await sut.clearCookie()
        let loggedIn = await sut.isLoggedIn
        XCTAssertFalse(loggedIn)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

```
swift test --filter KeychainCookieProviderTests 2>&1 | head -20
```

Expected: compile error containing `cannot find type 'KeychainCookieProvider'`

- [ ] **Step 3: Implement KeychainCookieProvider.swift**

Create `Sources/RPPlayer/Auth/KeychainCookieProvider.swift`:

```swift
import Foundation

/// Extends `CookieProvider` with mutable operations needed by `LoginWindowController`
/// and auth-expiry handling (implemented in PlaybackCoordinator, PR 6).
public protocol KeychainAuth: CookieProvider {
    var isLoggedIn: Bool { get async }
    func storeCookie(_ cookie: String) async throws
    func clearCookie() async
}

/// Keychain-backed implementation of `KeychainAuth`. Thread-safe via actor isolation.
/// Uses `kSecClassGenericPassword` with service `com.gvajda.RPPlayer`, account `rp-session-cookie`.
public actor KeychainCookieProvider: KeychainAuth {
    private static let service = "com.gvajda.RPPlayer"
    private static let account = "rp-session-cookie"

    private let keychainStore: any KeychainStore

    public init(keychainStore: any KeychainStore = SecItemKeychainStore()) {
        self.keychainStore = keychainStore
    }

    public func currentCookie() async -> String? {
        try? keychainStore.load(service: Self.service, account: Self.account)
    }

    public var isLoggedIn: Bool {
        (try? keychainStore.load(service: Self.service, account: Self.account)) != nil
    }

    public func storeCookie(_ cookie: String) async throws {
        try keychainStore.save(value: cookie, service: Self.service, account: Self.account)
    }

    public func clearCookie() async {
        try? keychainStore.delete(service: Self.service, account: Self.account)
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

```
swift test --filter KeychainCookieProviderTests 2>&1 | tail -10
```

Expected: `Executed 6 tests, with 0 failures`

- [ ] **Step 5: Commit**

```bash
git add Sources/RPPlayer/Auth/KeychainCookieProvider.swift \
        Tests/RPPlayerTests/Auth/KeychainCookieProviderTests.swift
git commit -m "feat(pr03): add KeychainAuth protocol and KeychainCookieProvider actor"
```

---

## Task 3: Cookie extraction logic

**Files:**
- Create: `Tests/RPPlayerTests/Auth/LoginWindowCookieExtractionTests.swift`
- Create: `Sources/RPPlayer/Auth/LoginWindow.swift` (stub with rpCookieString only)

- [ ] **Step 1: Write the failing test**

Create `Tests/RPPlayerTests/Auth/LoginWindowCookieExtractionTests.swift`:

```swift
import XCTest
import Foundation
@testable import RPPlayer

final class LoginWindowCookieExtractionTests: XCTestCase {
    private func cookie(name: String, value: String, domain: String = ".radioparadise.com") -> HTTPCookie {
        HTTPCookie(properties: [
            .name: name,
            .value: value,
            .domain: domain,
            .path: "/",
        ])!
    }

    func testValidRpCookiesReturnCookieString() {
        let cookies = [
            cookie(name: "C_username", value: "testuser"),
            cookie(name: "C_passwd",   value: "hashed"),
            cookie(name: "C_validated", value: "token"),
        ]
        let result = LoginWindowController.rpCookieString(from: cookies)
        XCTAssertNotNil(result)
        XCTAssertTrue(result!.contains("C_username=testuser"))
        XCTAssertTrue(result!.contains("C_passwd=hashed"))
        XCTAssertTrue(result!.contains("C_validated=token"))
    }

    func testAnonymousUsernameReturnsNil() {
        let cookies = [
            cookie(name: "C_username",  value: "anonymous"),
            cookie(name: "C_passwd",    value: "deleted"),
            cookie(name: "C_validated", value: "deleted"),
        ]
        XCTAssertNil(LoginWindowController.rpCookieString(from: cookies))
    }

    func testMissingCookiesReturnNil() {
        let cookies = [
            cookie(name: "C_username", value: "testuser"),
            // C_passwd and C_validated absent
        ]
        XCTAssertNil(LoginWindowController.rpCookieString(from: cookies))
    }

    func testNonRpDomainCookiesAreFiltered() {
        let cookies = [
            cookie(name: "C_username",  value: "testuser"),
            cookie(name: "C_passwd",    value: "hashed"),
            cookie(name: "C_validated", value: "token"),
            cookie(name: "C_username",  value: "evil", domain: ".evil.com"),
        ]
        // After filtering to radioparadise.com, count == 3, username != anonymous.
        let result = LoginWindowController.rpCookieString(from: cookies)
        XCTAssertNotNil(result)
        XCTAssertTrue(result!.contains("C_username=testuser"))
        XCTAssertFalse(result!.contains("evil"))
    }

    func testEmptyCookiesReturnNil() {
        XCTAssertNil(LoginWindowController.rpCookieString(from: []))
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

```
swift test --filter LoginWindowCookieExtractionTests 2>&1 | head -20
```

Expected: compile error containing `cannot find type 'LoginWindowController'`

- [ ] **Step 3: Create LoginWindow.swift with rpCookieString stub**

Create `Sources/RPPlayer/Auth/LoginWindow.swift`:

```swift
import AppKit
import WebKit

/// Hosts the Radio Paradise sign-in page. After successful login,
/// `WKHTTPCookieStoreObserver` detects the session cookies, stores them
/// via `KeychainAuth`, and closes the window.
///
/// `WKHTTPCookieStore` holds only a weak reference to the observer,
/// so no retain cycle exists and no explicit removal is required in deinit.
@MainActor
final class LoginWindowController: NSWindowController {
    private static let loginURL = URL(string: "https://radioparadise.com/account/sign-in")!
    private static let windowFrame = NSRect(x: 0, y: 0, width: 500, height: 620)

    private let webView: WKWebView
    private let keychainAuth: any KeychainAuth

    init(keychainAuth: any KeychainAuth) {
        self.keychainAuth = keychainAuth
        let webView = WKWebView(frame: Self.windowFrame, configuration: WKWebViewConfiguration())
        self.webView = webView

        let window = NSWindow(
            contentRect: Self.windowFrame,
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Sign in to Radio Paradise"
        window.contentView = webView
        window.center()

        super.init(window: window)
        webView.configuration.websiteDataStore.httpCookieStore.add(self)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("use init(keychainAuth:)") }

    func show() {
        showWindow(nil)
        webView.load(URLRequest(url: Self.loginURL))
    }

    /// Extracts the RP session cookie string from a set of `HTTPCookie` values.
    /// Returns `nil` when the three required cookies (`C_username`, `C_passwd`,
    /// `C_validated`) are absent or when the username is `"anonymous"` (not logged in).
    static func rpCookieString(from cookies: [HTTPCookie]) -> String? {
        let relevant = cookies.filter {
            $0.domain.hasSuffix("radioparadise.com") &&
            ["C_username", "C_passwd", "C_validated"].contains($0.name)
        }
        guard relevant.count == 3,
              let userCookie = relevant.first(where: { $0.name == "C_username" }),
              userCookie.value != "anonymous" else { return nil }
        return relevant.map { "\($0.name)=\($0.value)" }.joined(separator: "; ")
    }
}

extension LoginWindowController: WKHTTPCookieStoreObserver {
    // nonisolated required because WKHTTPCookieStoreObserver does not guarantee
    // delivery on @MainActor; the inner Task re-isolates to @MainActor for safety.
    nonisolated func cookiesDidChange(in cookieStore: WKHTTPCookieStore) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            // getAllCookies(_:) is the macOS 13-compatible callback form.
            let cookies: [HTTPCookie] = await withCheckedContinuation { cont in
                cookieStore.getAllCookies { cont.resume(returning: $0) }
            }
            guard let cookieString = LoginWindowController.rpCookieString(from: cookies) else { return }
            do {
                try await self.keychainAuth.storeCookie(cookieString)
                self.close()
            } catch {
                // Keychain write failure is non-fatal: user can retry via login window.
            }
        }
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

```
swift test --filter LoginWindowCookieExtractionTests 2>&1 | tail -10
```

Expected: `Executed 5 tests, with 0 failures`

- [ ] **Step 5: Commit**

```bash
git add Sources/RPPlayer/Auth/LoginWindow.swift \
        Tests/RPPlayerTests/Auth/LoginWindowCookieExtractionTests.swift
git commit -m "feat(pr03): add LoginWindowController and rpCookieString extraction helper"
```

---

## Task 4: Full build verification

**Files:**
- Verify: `Sources/RPPlayer/Auth/LoginWindow.swift` (already complete from Task 3)

`LoginWindow.swift` is already complete. This task verifies the AppKit/WebKit import chain compiles cleanly end-to-end.

- [ ] **Step 1: Build the full target**

```
swift build 2>&1 | tail -10
```

Expected: `Build complete!` with 0 errors.

If the linker reports `framework not found Security` or `framework not found WebKit`, add explicit linker settings to `Package.swift`:

```swift
.executableTarget(
    name: "RPPlayer",
    path: "Sources/RPPlayer",
    linkerSettings: [
        .linkedFramework("Security"),
        .linkedFramework("WebKit"),
    ]
)
```

Then re-run `swift build`.

- [ ] **Step 2: Run all tests**

```
swift test 2>&1 | tail -15
```

Expected: `Executed 34 tests, with 0 failures`

- [ ] **Step 3: Commit (only if Package.swift was changed)**

If Package.swift needed the linkerSettings change:
```bash
git add Package.swift
git commit -m "build(pr03): link Security and WebKit frameworks explicitly"
```

---

## Task 5: CookieProvider.swift cleanup

**Files:**
- Modify: `Sources/RPPlayer/Api/CookieProvider.swift`

- [ ] **Step 1: Remove the placeholder comment**

Open `Sources/RPPlayer/Api/CookieProvider.swift`. Replace the current `AnonymousCookieProvider` doc comment:

```swift
/// PR 2 placeholder: always anonymous. Replaced in PR 3 by a Keychain-backed implementation.
public struct AnonymousCookieProvider: CookieProvider {
```

with:

```swift
/// Always-anonymous `CookieProvider`. Used in tests and by components that
/// do not need authentication. For user-facing code, use `KeychainCookieProvider`.
public struct AnonymousCookieProvider: CookieProvider {
```

- [ ] **Step 2: Run all tests**

```
swift test 2>&1 | tail -10
```

Expected: `Executed 34 tests, with 0 failures`

- [ ] **Step 3: Commit**

```bash
git add Sources/RPPlayer/Api/CookieProvider.swift
git commit -m "docs(pr03): update AnonymousCookieProvider comment now that KeychainCookieProvider exists"
```

---

## Self-review

**Spec coverage check:**

| DESIGN.md requirement | Covered by |
|---|---|
| `KeychainAuth` — stores cookie blob in Keychain, provides cookie for HTTP requests | `KeychainCookieProvider` (Task 2) |
| `KeychainAuth` — knows whether user is logged in | `isLoggedIn: Bool` on `KeychainCookieProvider` (Task 2) |
| Cookie storage: macOS Keychain, single entry | `SecItemKeychainStore` with `kSecClassGenericPassword` (Task 1) |
| Authentication: embedded WKWebView, scrape cookie post-login | `LoginWindowController` + `WKHTTPCookieStoreObserver` (Task 3) |
| No password ever touches our process | WKWebView handles login entirely; we only read cookies | 
| `LoginWindow` hands cookies to `KeychainAuth` | `cookiesDidChange` → `keychainAuth.storeCookie` (Task 3) |
| Auth expired: clear keychain entry (error-handling §7) | `clearCookie()` on `KeychainCookieProvider` (Task 2) — called by PlaybackCoordinator in PR 6 |

**Placeholder scan:** None found.

**Type consistency:**
- `KeychainStore` protocol used in Tasks 1 and 2 ✓
- `KeychainAuth` protocol defined in Task 2, consumed by Task 3 ✓
- `LoginWindowController.rpCookieString(from:)` defined and tested in Task 3 ✓
- `InMemoryKeychainStore` defined in Task 1, used in Task 2 ✓

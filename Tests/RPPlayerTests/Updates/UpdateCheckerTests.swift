import XCTest
@testable import RPPlayer

final class UpdateCheckerTests: XCTestCase {
    private let fixedNow = Date(timeIntervalSince1970: 1_715_100_000)

    override func setUp() {
        super.setUp()
        StubURLProtocol.reset()
    }

    override func tearDown() {
        StubURLProtocol.reset()
        super.tearDown()
    }

    private func loadFixture(_ name: String) throws -> Data {
        let url = try XCTUnwrap(
            Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "Fixtures/Updates")
        )
        return try Data(contentsOf: url)
    }

    private func makeLogger() -> AppLogger {
        AppLogger.fileBacked(category: "test", directory: FileManager.default.temporaryDirectory)
    }

    @MainActor
    private func makeChecker(
        currentVersion: SemVer = SemVer(major: 0, minor: 4, patch: 1),
        store: StubConfigStore = StubConfigStore(initial: .default)
    ) -> UpdateChecker {
        let session = StubURLProtocol.makeSession()
        let now = fixedNow
        return UpdateChecker(
            currentVersion: currentVersion,
            repoOwner: "gvajda",
            repoName: "rp-player",
            urlSession: session,
            configStore: store,
            logger: makeLogger(),
            clock: { now }
        )
    }

    private static let endpoint = URL(
        string: "https://api.github.com/repos/gvajda/rp-player/releases/latest"
    )!

    @MainActor
    func testCheckNowAvailable() async throws {
        let body = try loadFixture("release_latest")
        StubURLProtocol.register(url: Self.endpoint, body: body, status: 200)
        let store = StubConfigStore(initial: .default)
        let checker = makeChecker(store: store)
        await checker.checkNow()

        let state = await checker.currentState
        guard case .available(let info, let dismissed) = state else {
            return XCTFail("expected .available, got \(state)")
        }
        XCTAssertEqual(info.tagName, "v0.5.0")
        XCTAssertFalse(dismissed)
        let lastCheck = store.settings.lastUpdateCheckAt
        let cachedTag = store.settings.cachedLatestRelease?.tagName
        XCTAssertEqual(lastCheck, fixedNow)
        XCTAssertEqual(cachedTag, "v0.5.0")
    }

    @MainActor
    func testCheckNowUpToDate() async throws {
        let body = try loadFixture("release_latest")
        StubURLProtocol.register(url: Self.endpoint, body: body, status: 200)
        let store = StubConfigStore(initial: .default)
        let checker = makeChecker(
            currentVersion: SemVer(major: 0, minor: 5, patch: 0),
            store: store
        )
        await checker.checkNow()

        let state = await checker.currentState
        guard case .upToDate(let when) = state else {
            return XCTFail("expected .upToDate, got \(state)")
        }
        XCTAssertEqual(when, fixedNow)
        let lastCheck = store.settings.lastUpdateCheckAt
        XCTAssertEqual(lastCheck, fixedNow)
    }

    @MainActor
    func testCheckNowFiltersPrerelease() async throws {
        let body = try loadFixture("release_latest_prerelease")
        StubURLProtocol.register(url: Self.endpoint, body: body, status: 200)
        let checker = makeChecker()
        await checker.checkNow()

        let state = await checker.currentState
        guard case .upToDate = state else {
            return XCTFail("prerelease should be treated as upToDate, got \(state)")
        }
    }

    @MainActor
    func testCheckNowFiltersDraft() async throws {
        let body = try loadFixture("release_latest_draft")
        StubURLProtocol.register(url: Self.endpoint, body: body, status: 200)
        let checker = makeChecker()
        await checker.checkNow()

        let state = await checker.currentState
        guard case .upToDate = state else {
            return XCTFail("draft should be treated as upToDate")
        }
    }

    @MainActor
    func testCheckNowNetworkErrorLeavesStateUnchanged() async throws {
        StubURLProtocol.registerError(url: Self.endpoint, error: URLError(.notConnectedToInternet))
        let store = StubConfigStore(initial: .default)
        let checker = makeChecker(store: store)
        await checker.checkNow()

        let state = await checker.currentState
        XCTAssertEqual(state, .unknown)
        let lastCheck = store.settings.lastUpdateCheckAt
        XCTAssertNil(lastCheck)
    }

    @MainActor
    func testCheckNowHttp500LeavesStateUnchanged() async throws {
        StubURLProtocol.register(url: Self.endpoint, body: Data(), status: 500)
        let store = StubConfigStore(initial: .default)
        let checker = makeChecker(store: store)
        await checker.checkNow()

        let state = await checker.currentState
        XCTAssertEqual(state, .unknown)
        let lastCheck = store.settings.lastUpdateCheckAt
        XCTAssertNil(lastCheck)
    }

    @MainActor
    func testCheckNowMalformedTagNotPersisted() async throws {
        let raw = """
        {"tag_name":"garbage","name":"x","body":"","draft":false,"prerelease":false,
         "published_at":"2026-05-08T10:00:00Z","html_url":"https://example.com","assets":[]}
        """.data(using: .utf8)!
        StubURLProtocol.register(url: Self.endpoint, body: raw, status: 200)
        let store = StubConfigStore(initial: .default)
        let checker = makeChecker(store: store)
        await checker.checkNow()

        let state = await checker.currentState
        XCTAssertEqual(state, .unknown)
        let lastCheck = store.settings.lastUpdateCheckAt
        XCTAssertNil(lastCheck)
    }

    @MainActor
    func testStartSkipsCheckWhenToggleOff() async throws {
        var settings = AppSettings.default
        settings.updateCheckEnabled = false
        let store = StubConfigStore(initial: settings)
        StubURLProtocol.register(url: Self.endpoint, body: Data(), status: 200)
        let checker = makeChecker(store: store)
        await checker.start()
        let state = await checker.currentState
        XCTAssertEqual(state, .unknown)
    }

    @MainActor
    func testStartSeedsStateFromCachedRelease() async throws {
        let cached = ReleaseInfo(
            tagName: "v0.5.0",
            version: SemVer(major: 0, minor: 5, patch: 0),
            publishedAt: Date(timeIntervalSince1970: 1_715_000_000),
            body: "old notes",
            htmlUrl: URL(string: "https://example.com")!,
            dmgAssetUrl: nil
        )
        var settings = AppSettings.default
        settings.cachedLatestRelease = cached
        settings.lastUpdateCheckAt = fixedNow.addingTimeInterval(-3600)
        settings.updateCheckEnabled = false
        let store = StubConfigStore(initial: settings)
        let checker = makeChecker(store: store)

        await checker.start()

        let state = await checker.currentState
        guard case .available(let info, let dismissed) = state else {
            return XCTFail("expected seeded .available, got \(state)")
        }
        XCTAssertEqual(info.tagName, "v0.5.0")
        XCTAssertFalse(dismissed)
    }

    @MainActor
    func testTickIfDueSkipsWhenLessThan24h() async throws {
        var settings = AppSettings.default
        settings.lastUpdateCheckAt = fixedNow.addingTimeInterval(-23 * 3600)
        let store = StubConfigStore(initial: settings)
        let body = try loadFixture("release_latest")
        StubURLProtocol.register(url: Self.endpoint, body: body, status: 200)
        let checker = makeChecker(store: store)
        await checker.tickIfDue()
        let state = await checker.currentState
        XCTAssertEqual(state, .unknown)
        let last = await store.settings.lastUpdateCheckAt
        XCTAssertEqual(last, fixedNow.addingTimeInterval(-23 * 3600))
    }

    @MainActor
    func testTickIfDueRunsWhen25hElapsed() async throws {
        var settings = AppSettings.default
        settings.lastUpdateCheckAt = fixedNow.addingTimeInterval(-25 * 3600)
        let store = StubConfigStore(initial: settings)
        let body = try loadFixture("release_latest")
        StubURLProtocol.register(url: Self.endpoint, body: body, status: 200)
        let checker = makeChecker(store: store)
        await checker.tickIfDue()
        let state = await checker.currentState
        guard case .available = state else {
            return XCTFail("expected check to fire and state to become .available, got \(state)")
        }
        let last = await store.settings.lastUpdateCheckAt
        XCTAssertEqual(last, fixedNow)
    }

    @MainActor
    func testTickIfDueSkipsWhenToggleOff() async throws {
        var settings = AppSettings.default
        settings.updateCheckEnabled = false
        settings.lastUpdateCheckAt = fixedNow.addingTimeInterval(-48 * 3600)
        let store = StubConfigStore(initial: settings)
        StubURLProtocol.register(url: Self.endpoint, body: Data(), status: 200)
        let checker = makeChecker(store: store)
        await checker.tickIfDue()
        let state = await checker.currentState
        XCTAssertEqual(state, .unknown)
    }

    @MainActor
    func testDismissedTagAutoResetsOnHigherRelease() async throws {
        var settings = AppSettings.default
        settings.dismissedUpdateVersion = "v0.5.0"
        let store = StubConfigStore(initial: settings)

        let bodySame = try loadFixture("release_latest")
        StubURLProtocol.register(url: Self.endpoint, body: bodySame, status: 200)
        let checker = makeChecker(
            currentVersion: SemVer(major: 0, minor: 4, patch: 1),
            store: store
        )
        await checker.checkNow()
        let firstState = await checker.currentState
        guard case .available(_, dismissedFromButton: true) = firstState else {
            return XCTFail("expected dismissedFromButton=true (same tag), got \(firstState)")
        }

        StubURLProtocol.reset()
        let bodyHigher = """
        {"tag_name":"v0.6.0","name":"v0.6.0","body":"new","draft":false,"prerelease":false,
         "published_at":"2026-05-09T10:00:00Z",
         "html_url":"https://github.com/gvajda/rp-player/releases/tag/v0.6.0",
         "assets":[
           {"name":"RP Player-v0.6.0.dmg",
            "browser_download_url":"https://example.com/x.dmg"}
         ]}
        """.data(using: .utf8)!
        StubURLProtocol.register(url: Self.endpoint, body: bodyHigher, status: 200)
        await checker.checkNow()
        let secondState = await checker.currentState
        guard case .available(let info, dismissedFromButton: false) = secondState else {
            return XCTFail("expected dismissedFromButton=false on higher tag, got \(secondState)")
        }
        XCTAssertEqual(info.tagName, "v0.6.0")
    }

    @MainActor
    func testDismissCurrentForButtonPersistsAndEmits() async throws {
        let body = try loadFixture("release_latest")
        StubURLProtocol.register(url: Self.endpoint, body: body, status: 200)
        let store = StubConfigStore(initial: .default)
        let checker = makeChecker(store: store)
        await checker.checkNow()
        let preState = await checker.currentState
        guard case .available(_, dismissedFromButton: false) = preState else {
            return XCTFail("setup: expected available, got \(preState)")
        }
        await checker.dismissCurrentForButton()
        let dismissed = await store.settings.dismissedUpdateVersion
        XCTAssertEqual(dismissed, "v0.5.0")
        let postState = await checker.currentState
        guard case .available(_, dismissedFromButton: true) = postState else {
            return XCTFail("expected dismissedFromButton=true after dismiss, got \(postState)")
        }
    }

    @MainActor
    func testToggleOffResetsStateToUnknownAndClearsCache() async throws {
        let body = try loadFixture("release_latest")
        StubURLProtocol.register(url: Self.endpoint, body: body, status: 200)
        let store = StubConfigStore(initial: .default)
        let checker = makeChecker(store: store)
        await checker.start()
        let startState = await checker.currentState
        guard case .available = startState else {
            return XCTFail("setup: expected .available after start, got \(startState)")
        }
        let cachedBefore = store.settings.cachedLatestRelease
        XCTAssertNotNil(cachedBefore)

        try await store.update { $0.updateCheckEnabled = false }
        try await Task.sleep(nanoseconds: 50_000_000)

        let state = await checker.currentState
        XCTAssertEqual(state, .unknown)
        let cached = await store.settings.cachedLatestRelease
        XCTAssertNil(cached)
    }
}

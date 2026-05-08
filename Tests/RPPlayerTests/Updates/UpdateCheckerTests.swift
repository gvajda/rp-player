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
}

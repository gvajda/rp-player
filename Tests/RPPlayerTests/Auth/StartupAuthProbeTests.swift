import XCTest
@testable import RPPlayer

@MainActor
private final class BoolFlag {
    private(set) var value = false
    func set() { value = true }
}

@MainActor
final class StartupAuthProbeTests: XCTestCase {
    private var auth: StubKeychainAuth!
    private var api: MockRpApiClient!

    override func setUp() async throws {
        auth = StubKeychainAuth()
        api = MockRpApiClient()
    }

    func testNoOpWhenNotSignedIn() async throws {
        auth.loggedIn = false
        let flag = BoolFlag()

        let result = await StartupAuthProbe.run(api: api, auth: auth) {
            flag.set()
        }

        XCTAssertEqual(result, .skipped)
        let calls = await api.calls
        XCTAssertFalse(
            calls.contains(where: { if case .authState = $0 { return true } else { return false } }),
            "must not call authState when not signed in"
        )
        let fired = flag.value
        XCTAssertFalse(fired)
    }

    func testKeepsCookieWhenServerReturnsRealUsername() async throws {
        auth.loggedIn = true
        auth.username = "alice"
        try await auth.storeCookie("C_username=alice; C_passwd=hash; C_validated=tok")
        await api.setAuthStateResponse(Auth(
            userId: "1", postOk: "t", username: "alice", level: "5",
            countryCode: "US", avatar: nil, privmsgNew: false, status: "success"
        ))
        let flag = BoolFlag()

        let result = await StartupAuthProbe.run(api: api, auth: auth) {
            flag.set()
        }

        XCTAssertEqual(result, .stillValid)
        XCTAssertTrue(auth.loggedIn)
        let fired = flag.value
        XCTAssertFalse(fired)
    }

    func testClearsCookieWhenServerReturnsAnonymous() async throws {
        auth.loggedIn = true
        auth.username = "alice"
        try await auth.storeCookie("C_username=alice; C_passwd=hash; C_validated=tok")
        await api.setAuthStateResponse(Auth(
            userId: "0", postOk: "f", username: "anonymous", level: "1",
            countryCode: "US", avatar: nil, privmsgNew: false, status: "success"
        ))
        let flag = BoolFlag()

        let result = await StartupAuthProbe.run(api: api, auth: auth) {
            flag.set()
        }

        XCTAssertEqual(result, .cleared)
        XCTAssertFalse(auth.loggedIn)
        let fired = flag.value
        XCTAssertTrue(fired)
    }

    func testClearsCookieOnAuthFailure401() async throws {
        auth.loggedIn = true
        try await auth.storeCookie("C_username=alice; C_passwd=hash; C_validated=tok")
        await api.setAuthStateError(RpApiError.invalidResponse(statusCode: 401, body: Data()))
        let flag = BoolFlag()

        let result = await StartupAuthProbe.run(api: api, auth: auth) {
            flag.set()
        }

        XCTAssertEqual(result, .cleared)
        XCTAssertFalse(auth.loggedIn)
        let fired = flag.value
        XCTAssertTrue(fired)
    }

    func testKeepsCookieWhenNetworkErrorIsTransient() async throws {
        auth.loggedIn = true
        try await auth.storeCookie("C_username=alice; C_passwd=hash; C_validated=tok")
        await api.setAuthStateError(RpApiError.network(URLError(.notConnectedToInternet)))
        let flag = BoolFlag()

        let result = await StartupAuthProbe.run(api: api, auth: auth) {
            flag.set()
        }

        XCTAssertEqual(result, .networkUnavailable)
        XCTAssertTrue(auth.loggedIn, "transient network errors must not clear cookie")
        let fired = flag.value
        XCTAssertFalse(fired)
    }
}

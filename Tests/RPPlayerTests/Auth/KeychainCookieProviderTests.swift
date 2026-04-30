import XCTest
@testable import RPPlayer

private final class ThrowingKeychainStore: KeychainStore, @unchecked Sendable {
    func load(service: String, account: String) throws -> String? { nil }
    func save(value: String, service: String, account: String) throws {
        throw KeychainError.unexpectedStatus(-1)
    }
    func delete(service: String, account: String) throws {}
}

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
        let loggedIn = sut.isLoggedIn
        XCTAssertFalse(loggedIn)
    }

    func testIsLoggedInTrueAfterStoringCookie() async throws {
        try await sut.storeCookie("C_username=foo; C_passwd=hash; C_validated=tok")
        let loggedIn = sut.isLoggedIn
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
        let loggedIn = sut.isLoggedIn
        XCTAssertFalse(loggedIn)
    }

    func testStoreCookiePropagatesKeychainError() async {
        let throwingStore = ThrowingKeychainStore()
        let provider = KeychainCookieProvider(keychainStore: throwingStore)
        do {
            try await provider.storeCookie("C_username=foo")
            XCTFail("Expected storeCookie to throw but it succeeded")
        } catch is KeychainError {
            // expected — KeychainStore write failure is propagated
        } catch {
            XCTFail("Expected KeychainError but got \(type(of: error)): \(error)")
        }
    }

    func testCurrentUsernameIsNilWhenNothingStored() {
        XCTAssertNil(sut.currentUsername)
    }

    func testCurrentUsernameReturnsValueFromCookie() async throws {
        try await sut.storeCookie("C_passwd=hash; C_username=alice; C_validated=tok")
        XCTAssertEqual(sut.currentUsername, "alice")
    }

    func testCurrentUsernameIsNilWhenAnonymous() async throws {
        try await sut.storeCookie("C_username=anonymous; C_passwd=deleted; C_validated=deleted")
        XCTAssertNil(sut.currentUsername)
    }

    func testCurrentUsernameIsNilAfterClear() async throws {
        try await sut.storeCookie("C_username=alice; C_passwd=hash; C_validated=tok")
        await sut.clearCookie()
        XCTAssertNil(sut.currentUsername)
    }

    func testCurrentUsernamePicksRightFieldAmongOtherCookies() async throws {
        try await sut.storeCookie("PHPSESSID=abc; C_username=bob; rp_pref=dark; C_passwd=hash; C_validated=tok")
        XCTAssertEqual(sut.currentUsername, "bob")
    }
}

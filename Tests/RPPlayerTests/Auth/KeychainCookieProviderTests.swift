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

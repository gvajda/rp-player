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
            cookie(name: "C_username",  value: "testuser"),
            cookie(name: "C_passwd",    value: "hashed"),
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

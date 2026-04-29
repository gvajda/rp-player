import XCTest
import CMpv

final class LibmpvLinkageTests: XCTestCase {
    // Pinned API version: 2.1 — see Vendor/libmpv/README.md.
    // Bump this expectation whenever the vendored libmpv is updated.
    func testReportsExpectedApiVersion() {
        let v = mpv_client_api_version()
        let major = (v >> 16) & 0xFFFF
        let minor = v & 0xFFFF
        XCTAssertEqual(major, 2, "expected libmpv API major version 2")
        XCTAssertEqual(minor, 1, "expected libmpv API minor version 1")
    }
}

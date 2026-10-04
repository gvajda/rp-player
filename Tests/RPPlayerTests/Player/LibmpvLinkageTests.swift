import XCTest
import CMpv
import Darwin

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

    // Confirms the Vendor/libmpv/lib image is the one libmpv actually loaded, and that it carries bs2b + ladspa.
    func testVendoredAvfilterHasLadspaAndBs2b() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let path = root.appendingPathComponent("Vendor/libmpv/lib/libavfilter.dylib").path
        let handle = try XCTUnwrap(dlopen(path, RTLD_NOW | RTLD_LOCAL),
                                   dlerror().map { String(cString: $0) } ?? "dlopen failed")
        defer { dlclose(handle) }
        let sym = try XCTUnwrap(dlsym(handle, "avfilter_get_by_name"))
        typealias GetByName = @convention(c) (UnsafePointer<CChar>) -> UnsafeRawPointer?
        let getByName = unsafeBitCast(sym, to: GetByName.self)
        XCTAssertNotNil(getByName("bs2b"), "vendored libavfilter lost bs2b — wrong flavour or wrong image")
        XCTAssertNotNil(getByName("ladspa"), "vendored libavfilter lacks ladspa — rebuild with --enable-ladspa")
        XCTAssertEqual(dlsym(UnsafeMutableRawPointer(bitPattern: -2), "avfilter_get_by_name"), sym,
                        "libmpv loaded a libavfilter other than Vendor/libmpv/lib")
    }
}

import XCTest

@discardableResult
func waitUntil(_ condition: @Sendable () async -> Bool, timeout: TimeInterval) async throws -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if await condition() { return true }
        try await Task.sleep(nanoseconds: 20_000_000)
    }
    XCTFail("waitUntil timed out after \(timeout)s")
    return false
}

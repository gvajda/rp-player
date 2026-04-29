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
        XCTAssertNoThrow(try sut.delete(service: service, account: account))
    }

    func testSaveOverwritesExisting() throws {
        try sut.save(value: "C_username=old", service: service, account: account)
        try sut.save(value: "C_username=new", service: service, account: account)
        let loaded = try sut.load(service: service, account: account)
        XCTAssertEqual(loaded, "C_username=new")
    }
}

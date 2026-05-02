import XCTest
import UserNotifications
@testable import RPPlayer

private class RecordingCenter: UNUserNotificationCenterProtocol, @unchecked Sendable {
    private let lock = NSLock()
    private var _identifiers: [String] = []

    var identifiers: [String] {
        lock.withLock { _identifiers }
    }

    func requestAuthorization(options: UNAuthorizationOptions) async throws -> Bool { true }

    func add(_ request: UNNotificationRequest) async throws {
        lock.withLock { _identifiers.append(request.identifier) }
    }
}

private class FakeUNCenter: UNUserNotificationCenterProtocol, @unchecked Sendable {
    private let lock = NSLock()
    private var _authorizationResult: Result<Bool, Error> = .success(true)
    private var _requestedOptions: UNAuthorizationOptions = []
    private var _addedRequestCount: Int = 0

    var authorizationResult: Result<Bool, Error> {
        get { lock.withLock { _authorizationResult } }
        set { lock.withLock { _authorizationResult = newValue } }
    }
    var requestedOptions: UNAuthorizationOptions {
        lock.withLock { _requestedOptions }
    }
    var addedRequestCount: Int {
        lock.withLock { _addedRequestCount }
    }

    func requestAuthorization(options: UNAuthorizationOptions) async throws -> Bool {
        lock.withLock { _requestedOptions = options }
        return try lock.withLock { _authorizationResult }.get()
    }

    func add(_ request: UNNotificationRequest) async throws {
        lock.withLock { _addedRequestCount += 1 }
    }
}

@MainActor
final class NotificationServiceTests: XCTestCase {
    private var fakeCenter: FakeUNCenter!
    private var sut: LiveNotificationService!

    override func setUp() async throws {
        fakeCenter = FakeUNCenter()
        sut = LiveNotificationService(center: fakeCenter)
    }

    func testRequestAuthorizationDelegatesToCenter() async throws {
        fakeCenter.authorizationResult = .success(true)
        let granted = try await sut.requestAuthorization()
        XCTAssertTrue(granted)
        XCTAssertEqual(fakeCenter.requestedOptions, [.alert, .sound])
    }

    func testNotifyPostsExpectedTitleAndSubtitleWhenNoArt() async throws {
        try await sut.notify(title: "Artist — Title", subtitle: "Album · Channel", attachmentURL: nil)
        XCTAssertEqual(fakeCenter.addedRequestCount, 1)
    }

    func testNotifyAttachesAttachmentWhenURLProvided() async throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("notif-test-\(UUID().uuidString).png")
        try Data([0x89, 0x50, 0x4e, 0x47]).write(to: tmp)
        defer { try? FileManager.default.removeItem(at: tmp) }

        try await sut.notify(title: "T", subtitle: "S", attachmentURL: tmp)
        XCTAssertEqual(fakeCenter.addedRequestCount, 1)
    }

    func testNotifySwallowsAttachmentInitFailureAndPostsAnyway() async throws {
        let bogus = URL(fileURLWithPath: "/does/not/exist.xyz")
        try await sut.notify(title: "T", subtitle: "S", attachmentURL: bogus)
        XCTAssertEqual(fakeCenter.addedRequestCount, 1)
    }

    func testNotifyWithIdentifierSuffixComposesPipeFormat() async throws {
        let center = RecordingCenter()
        let service = LiveNotificationService(center: center)
        try await service.notify(title: "T", subtitle: "S", attachmentURL: nil, identifierSuffix: "12345")
        let identifiers = center.identifiers
        XCTAssertEqual(identifiers.count, 1)
        XCTAssertTrue(identifiers[0].contains("|12345"),
                      "identifier should end with '|12345', got: \(identifiers[0])")
        XCTAssertEqual(identifiers[0].split(separator: "|").count, 2)
    }

    func testNotifyWithoutSuffixHasNoSeparator() async throws {
        let center = RecordingCenter()
        let service = LiveNotificationService(center: center)
        try await service.notify(title: "T", subtitle: "S", attachmentURL: nil)
        let identifiers = center.identifiers
        XCTAssertFalse(identifiers[0].contains("|"))
    }

    func testExtractSongIdParsesSuffixForm() {
        let id = "ABC-DEF-GHI|9999"
        XCTAssertEqual(LiveNotificationService.extractSongId(from: id), "9999")
    }

    func testExtractSongIdReturnsNilForLegacyIdWithoutSeparator() {
        XCTAssertNil(LiveNotificationService.extractSongId(from: "no-separator"))
    }

    func testExtractSongIdReturnsNilForEmptySuffix() {
        XCTAssertNil(LiveNotificationService.extractSongId(from: "uuid|"))
    }
}

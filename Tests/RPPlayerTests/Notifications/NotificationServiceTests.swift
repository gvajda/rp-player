import AppKit
import UserNotifications
import XCTest
@testable import RPPlayer

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
        try await sut.notify(
            title: "Artist — Title",
            subtitle: "Album · Channel",
            attachmentURL: nil
        )
        XCTAssertEqual(fakeCenter.addedRequests.count, 1)
        let request = fakeCenter.addedRequests[0]
        XCTAssertEqual(request.content.title, "Artist — Title")
        XCTAssertEqual(request.content.subtitle, "Album · Channel")
        XCTAssertTrue(request.content.attachments.isEmpty)
        XCTAssertNil(request.trigger)
    }

    func testNotifyAttachesAttachmentWhenURLProvided() async throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("notif-test-\(UUID().uuidString).png")
        try Data([0x89, 0x50, 0x4e, 0x47]).write(to: tmp)
        defer { try? FileManager.default.removeItem(at: tmp) }

        try await sut.notify(
            title: "T", subtitle: "S", attachmentURL: tmp
        )

        let attachments = fakeCenter.addedRequests[0].content.attachments
        XCTAssertEqual(attachments.count, 1)
    }

    func testNotifySwallowsAttachmentInitFailureAndPostsAnyway() async throws {
        let bogus = URL(fileURLWithPath: "/does/not/exist.xyz")
        try await sut.notify(title: "T", subtitle: "S", attachmentURL: bogus)
        XCTAssertEqual(fakeCenter.addedRequests.count, 1)
        XCTAssertTrue(fakeCenter.addedRequests[0].content.attachments.isEmpty)
    }
}

final class FakeUNCenter: UNUserNotificationCenterProtocol, @unchecked Sendable {
    private let lock = NSLock()
    private var _authorizationResult: Result<Bool, Error> = .success(true)
    private var _requestedOptions: UNAuthorizationOptions = []
    private var _addedRequests: [UNNotificationRequest] = []

    var authorizationResult: Result<Bool, Error> {
        get { lock.withLock { _authorizationResult } }
        set { lock.withLock { _authorizationResult = newValue } }
    }
    var requestedOptions: UNAuthorizationOptions {
        lock.withLock { _requestedOptions }
    }
    var addedRequests: [UNNotificationRequest] {
        lock.withLock { _addedRequests }
    }

    func requestAuthorization(options: UNAuthorizationOptions) async throws -> Bool {
        lock.withLock { _requestedOptions = options }
        return try lock.withLock { _authorizationResult }.get()
    }

    func add(_ request: UNNotificationRequest) async throws {
        lock.withLock { _addedRequests.append(request) }
    }
}

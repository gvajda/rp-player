import Foundation
import UserNotifications

public protocol UNUserNotificationCenterProtocol: Sendable {
    func requestAuthorization(options: UNAuthorizationOptions) async throws -> Bool
    func add(_ request: UNNotificationRequest) async throws
}

extension UNUserNotificationCenter: UNUserNotificationCenterProtocol {}

public protocol NotificationService: Sendable {
    func requestAuthorization() async throws -> Bool
    func notify(title: String, subtitle: String, attachmentURL: URL?) async throws
}

public actor LiveNotificationService: NotificationService {
    private let center: any UNUserNotificationCenterProtocol

    public init(center: any UNUserNotificationCenterProtocol = UNUserNotificationCenter.current()) {
        self.center = center
    }

    public func requestAuthorization() async throws -> Bool {
        try await center.requestAuthorization(options: [.alert, .sound])
    }

    public func notify(title: String, subtitle: String, attachmentURL: URL?) async throws {
        let content = UNMutableNotificationContent()
        content.title = title
        content.subtitle = subtitle
        if let url = attachmentURL,
           let attachment = try? UNNotificationAttachment(identifier: url.lastPathComponent, url: url) {
            content.attachments = [attachment]
        }
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        try await center.add(request)
    }
}

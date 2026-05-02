import Foundation
import UserNotifications

public protocol UNUserNotificationCenterProtocol: Sendable {
    func requestAuthorization(options: UNAuthorizationOptions) async throws -> Bool
    func add(_ request: UNNotificationRequest) async throws
}

extension UNUserNotificationCenter: UNUserNotificationCenterProtocol {}

public protocol NotificationService: Sendable {
    func requestAuthorization() async throws -> Bool
    func notify(title: String, subtitle: String, attachmentURL: URL?, identifierSuffix: String?) async throws
}

public extension NotificationService {
    func notify(title: String, subtitle: String, attachmentURL: URL?) async throws {
        try await notify(title: title, subtitle: subtitle, attachmentURL: attachmentURL, identifierSuffix: nil)
    }
}

public actor LiveNotificationService: NotificationService {
    private let center: any UNUserNotificationCenterProtocol

    public init(center: any UNUserNotificationCenterProtocol) {
        self.center = center
    }

    public func requestAuthorization() async throws -> Bool {
        try await center.requestAuthorization(options: [.alert, .sound])
    }

    public func notify(title: String, subtitle: String, attachmentURL: URL?, identifierSuffix: String?) async throws {
        let content = UNMutableNotificationContent()
        content.title = title
        content.subtitle = subtitle
        if let url = attachmentURL,
           let attachment = try? UNNotificationAttachment(identifier: url.lastPathComponent, url: url) {
            content.attachments = [attachment]
        }
        let identifier: String
        if let suffix = identifierSuffix, !suffix.isEmpty {
            identifier = "\(UUID().uuidString)|\(suffix)"
        } else {
            identifier = UUID().uuidString
        }
        let request = UNNotificationRequest(identifier: identifier, content: content, trigger: nil)
        try await center.add(request)
    }

    public static func extractSongId(from requestIdentifier: String) -> String? {
        let parts = requestIdentifier.split(separator: "|", maxSplits: 1, omittingEmptySubsequences: false)
        guard parts.count == 2 else { return nil }
        let suffix = String(parts[1])
        return suffix.isEmpty ? nil : suffix
    }
}

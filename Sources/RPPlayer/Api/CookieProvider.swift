import Foundation

/// Supplies a `Cookie` header value for outgoing RP API requests.
/// Implementations are responsible for deciding whether the user is
/// currently authenticated — `nil` means "send no Cookie header".
public protocol CookieProvider: Sendable {
    func currentCookie() async -> String?
}

// Always anonymous. For authenticated use, see KeychainCookieProvider.
public struct AnonymousCookieProvider: CookieProvider {
    public init() {}
    public func currentCookie() async -> String? { nil }
}

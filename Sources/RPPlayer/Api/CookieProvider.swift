import Foundation

/// Supplies a `Cookie` header value for outgoing RP API requests.
/// Implementations are responsible for deciding whether the user is
/// currently authenticated — `nil` means "send no Cookie header".
public protocol CookieProvider: Sendable {
    func currentCookie() async -> String?
}

/// PR 2 placeholder: always anonymous. Replaced in PR 3 by a Keychain-backed implementation.
public struct AnonymousCookieProvider: CookieProvider {
    public init() {}
    public func currentCookie() async -> String? { nil }
}

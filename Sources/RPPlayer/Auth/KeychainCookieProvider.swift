import Foundation

/// Extends `CookieProvider` with mutable operations needed by `LoginWindowController`
/// and auth-expiry handling (PlaybackCoordinator, PR 6).
public protocol KeychainAuth: CookieProvider {
    var isLoggedIn: Bool { get async }
    func storeCookie(_ cookie: String) async throws
    func clearCookie() async
}

/// Keychain-backed `CookieProvider`. Uses `kSecClassGenericPassword` with
/// service `com.gvajda.RPPlayer`, account `rp-session-cookie`.
public actor KeychainCookieProvider: KeychainAuth {
    private static let service = "com.gvajda.RPPlayer"
    private static let account = "rp-session-cookie"

    private let keychainStore: any KeychainStore

    public init(keychainStore: any KeychainStore = SecItemKeychainStore()) {
        self.keychainStore = keychainStore
    }

    public func currentCookie() async -> String? {
        try? keychainStore.load(service: Self.service, account: Self.account)
    }

    public var isLoggedIn: Bool {
        (try? keychainStore.load(service: Self.service, account: Self.account)) != nil
    }

    public func storeCookie(_ cookie: String) async throws {
        try keychainStore.save(value: cookie, service: Self.service, account: Self.account)
    }

    public func clearCookie() async {
        try? keychainStore.delete(service: Self.service, account: Self.account)
    }
}

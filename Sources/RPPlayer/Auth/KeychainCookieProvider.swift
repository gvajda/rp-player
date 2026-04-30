import Foundation

public protocol KeychainAuth: CookieProvider {
    var isLoggedIn: Bool { get }
    var currentUsername: String? { get }
    func storeCookie(_ cookie: String) async throws
    func clearCookie() async
}

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

    public nonisolated var isLoggedIn: Bool {
        (try? keychainStore.load(service: Self.service, account: Self.account)) != nil
    }

    public nonisolated var currentUsername: String? {
        guard let raw = try? keychainStore.load(service: Self.service, account: Self.account) else {
            return nil
        }
        return Self.parseUsername(from: raw)
    }

    public func storeCookie(_ cookie: String) async throws {
        try keychainStore.save(value: cookie, service: Self.service, account: Self.account)
    }

    public func clearCookie() async {
        try? keychainStore.delete(service: Self.service, account: Self.account)
    }

    static func parseUsername(from cookieString: String) -> String? {
        for pair in cookieString.split(separator: ";") {
            let trimmed = pair.trimmingCharacters(in: .whitespaces)
            guard let eq = trimmed.firstIndex(of: "=") else { continue }
            let name = String(trimmed[..<eq])
            if name == "C_username" {
                let value = String(trimmed[trimmed.index(after: eq)...])
                return value == "anonymous" ? nil : value
            }
        }
        return nil
    }
}

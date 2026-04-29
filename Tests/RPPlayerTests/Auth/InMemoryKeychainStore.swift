@testable import RPPlayer

/// Dictionary-backed KeychainStore for tests. Thread-safety provided by
/// the actor isolation of KeychainCookieProvider — not needed here itself.
final class InMemoryKeychainStore: KeychainStore, @unchecked Sendable {
    private var storage: [String: String] = [:]

    func load(service: String, account: String) throws -> String? {
        storage["\(service):\(account)"]
    }

    func save(value: String, service: String, account: String) throws {
        storage["\(service):\(account)"] = value
    }

    func delete(service: String, account: String) throws {
        storage.removeValue(forKey: "\(service):\(account)")
    }
}

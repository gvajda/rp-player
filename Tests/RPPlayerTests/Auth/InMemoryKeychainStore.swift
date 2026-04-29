@testable import RPPlayer

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

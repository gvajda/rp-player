import Foundation
@testable import RPPlayer

@MainActor
final class StubConfigStore: ConfigStore {
    var current: AppSettings
    var continuations: [AsyncStream<AppSettings>.Continuation] = []

    init(initial: AppSettings) { self.current = initial }

    var settings: AppSettings { current }

    var changes: AsyncStream<AppSettings> {
        AsyncStream { continuation in
            continuation.yield(current)
            continuations.append(continuation)
        }
    }

    func update(_ mutate: @Sendable (inout AppSettings) -> Void) async throws {
        var copy = current
        mutate(&copy)
        guard copy != current else { return }
        current = copy
        continuations.forEach { $0.yield(copy) }
    }
}

@MainActor
final class StubAudioDeviceCatalog: AudioDeviceCatalog {
    var current: [AudioDevice]
    var continuations: [AsyncStream<[AudioDevice]>.Continuation] = []

    init(initial: [AudioDevice]) { self.current = initial }

    var devices: [AudioDevice] { current }

    var changes: AsyncStream<[AudioDevice]> {
        AsyncStream { continuation in
            continuation.yield(current)
            continuations.append(continuation)
        }
    }

    func setDevices(_ devices: [AudioDevice]) {
        current = devices
        continuations.forEach { $0.yield(devices) }
    }
}

@MainActor
final class StubKeychainAuth: KeychainAuth {
    var loggedIn: Bool = false
    var storedCookie: String?

    nonisolated var isLoggedIn: Bool {
        MainActor.assumeIsolated { loggedIn }
    }

    nonisolated func currentCookie() async -> String? {
        await MainActor.run { storedCookie }
    }

    func storeCookie(_ cookie: String) async throws {
        storedCookie = cookie
        loggedIn = true
    }

    func clearCookie() async {
        storedCookie = nil
        loggedIn = false
    }
}

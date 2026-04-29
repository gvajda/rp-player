import Foundation
@testable import RPPlayer

/// Programmable AudioDeviceLister for tests. Mutate `_devices` to simulate
/// hot-plug events; tests then drive the catalog by calling reload() on the catalog under test.
// @unchecked Sendable: NSLock guards the only mutable state.
final class StubAudioDeviceLister: AudioDeviceLister, @unchecked Sendable {
    private let lock = NSLock()
    private var _devices: [AudioDevice]

    init(devices: [AudioDevice]) {
        self._devices = devices
    }

    func currentDevices() -> [AudioDevice] {
        lock.lock(); defer { lock.unlock() }
        return _devices
    }

    func setDevices(_ devices: [AudioDevice]) {
        lock.lock(); defer { lock.unlock() }
        _devices = devices
    }
}

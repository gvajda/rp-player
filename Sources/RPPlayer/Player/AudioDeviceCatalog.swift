import Foundation

/// High-level interface consumed by `SettingsView`. Provides the current snapshot
/// and an `AsyncStream` of every subsequent change. Mirrors the
/// `JSONConfigStore.changes` pattern: the stream yields the current snapshot
/// immediately on subscription, then yields whenever the device set changes.
public protocol AudioDeviceCatalog: Sendable {
    var devices: [AudioDevice] { get async }
    var changes: AsyncStream<[AudioDevice]> { get async }
}

/// Low-level seam: returns the current set of CoreAudio output devices on demand.
/// Production code uses `CoreAudioDeviceLister` (added in Task 3); tests use
/// `StubAudioDeviceLister` to drive the actor without real hardware.
public protocol AudioDeviceLister: Sendable {
    func currentDevices() -> [AudioDevice]
}

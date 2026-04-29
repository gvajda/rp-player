import CoreAudio
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
/// Production code uses `CoreAudioDeviceLister` (in CoreAudioDeviceLister.swift);
/// tests use `StubAudioDeviceLister` to drive the actor without real hardware.
public protocol AudioDeviceLister: Sendable {
    func currentDevices() -> [AudioDevice]
}

public actor CoreAudioDeviceCatalog: AudioDeviceCatalog {
    private let lister: any AudioDeviceLister
    private var current: [AudioDevice]
    private var continuations: [UUID: AsyncStream<[AudioDevice]>.Continuation] = [:]
    private var hotplugListener: HotplugListener?

    public init(lister: any AudioDeviceLister) {
        self.lister = lister
        self.current = lister.currentDevices()
    }

    public var devices: [AudioDevice] { current }

    /// Subscribes a new continuation atomically: by the time the stream is returned,
    /// the subscriber is registered and has been yielded the current snapshot.
    public var changes: AsyncStream<[AudioDevice]> {
        let id = UUID()
        return AsyncStream { continuation in
            self.continuations[id] = continuation
            continuation.yield(self.current)
            continuation.onTermination = { [weak self] _ in
                Task { [weak self] in await self?.unregister(id: id) }
            }
        }
    }

    /// Re-enumerates devices via the lister and yields the new snapshot to every
    /// subscriber if the list changed. Called from the CoreAudio hot-plug listener
    /// (Task 4) and directly from tests.
    public func reload() {
        let new = lister.currentDevices()
        guard new != current else { return }
        current = new
        for c in continuations.values {
            c.yield(new)
        }
    }

    /// Starts observing `kAudioHardwarePropertyDevices`. Idempotent.
    /// Production code calls this once after constructing the catalog.
    public func startWatching() {
        guard hotplugListener == nil else { return }
        hotplugListener = HotplugListener { [weak self] in
            Task { await self?.reload() }
        }
    }

    /// Stops observing hot-plug events. Idempotent.
    public func stopWatching() {
        hotplugListener = nil
    }

    private func unregister(id: UUID) {
        continuations.removeValue(forKey: id)
    }
}

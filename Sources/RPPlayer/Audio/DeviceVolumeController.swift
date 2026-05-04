import CoreAudio
import Foundation

public actor DeviceVolumeController {
    public init() {}

    @discardableResult
    public func setVolumeMax(deviceUID: String) -> Bool {
        guard let target = deviceID(forUID: deviceUID) else { return false }
        // Master element first (element 0); many DACs expose only this.
        if setScalar(target, element: kAudioObjectPropertyElementMain, value: 1.0) { return true }
        // Per-channel fallback: stereo devices typically expose L=1, R=2.
        let left = setScalar(target, element: 1, value: 1.0)
        let right = setScalar(target, element: 2, value: 1.0)
        return left || right
    }

    /// Reads the current device output volume scalar (0.0...1.0).
    /// Returns the master element's value when present; otherwise the average
    /// of L/R channels. Returns `nil` if the device exposes no readable volume.
    public func currentVolume(deviceUID: String) -> Float? {
        guard let target = deviceID(forUID: deviceUID) else { return nil }
        if let master = getScalar(target, element: kAudioObjectPropertyElementMain) {
            return master
        }
        let left = getScalar(target, element: 1)
        let right = getScalar(target, element: 2)
        switch (left, right) {
        case let (l?, r?): return (l + r) / 2
        case let (l?, nil): return l
        case let (nil, r?): return r
        default: return nil
        }
    }

    private func getScalar(_ id: AudioDeviceID, element: AudioObjectPropertyElement) -> Float32? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyVolumeScalar,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: element
        )
        guard AudioObjectHasProperty(id, &address) else { return nil }
        var size = UInt32(MemoryLayout<Float32>.size)
        var value: Float32 = 0
        let status = AudioObjectGetPropertyData(id, &address, 0, nil, &size, &value)
        return status == noErr ? value : nil
    }

    private func setScalar(_ id: AudioDeviceID, element: AudioObjectPropertyElement, value: Float32) -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyVolumeScalar,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: element
        )
        var settable: DarwinBoolean = false
        guard AudioObjectIsPropertySettable(id, &address, &settable) == noErr, settable.boolValue else {
            return false
        }
        var v = value
        let status = AudioObjectSetPropertyData(
            id, &address, 0, nil,
            UInt32(MemoryLayout<Float32>.size), &v
        )
        return status == noErr
    }

    private func deviceID(forUID uid: String) -> AudioDeviceID? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyTranslateUIDToDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var deviceID: AudioDeviceID = kAudioDeviceUnknown
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var cfUID = uid as CFString
        let status = withUnsafeMutablePointer(to: &cfUID) { ptr -> OSStatus in
            AudioObjectGetPropertyData(
                AudioObjectID(kAudioObjectSystemObject),
                &address,
                UInt32(MemoryLayout<CFString>.size),
                ptr,
                &size,
                &deviceID
            )
        }
        guard status == noErr, deviceID != kAudioDeviceUnknown else { return nil }
        return deviceID
    }
}

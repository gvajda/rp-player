import CoreAudio
import Foundation

public actor HogModeController {
    private var hoggedDeviceID: AudioDeviceID?

    public init() {}

    public var isHogging: Bool { hoggedDeviceID != nil }

    public func acquire(deviceUID: String) -> Bool {
        guard let target = deviceID(forUID: deviceUID) else { return false }
        if let current = hoggedDeviceID, current == target { return true }
        if hoggedDeviceID != nil {
            releaseHog()
        }
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyHogMode,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var pid: pid_t = getpid()
        let setStatus = AudioObjectSetPropertyData(
            target, &address, 0, nil,
            UInt32(MemoryLayout<pid_t>.size), &pid
        )
        guard setStatus == noErr else { return false }
        var size = UInt32(MemoryLayout<pid_t>.size)
        var actual: pid_t = -1
        let getStatus = AudioObjectGetPropertyData(
            target, &address, 0, nil, &size, &actual
        )
        guard getStatus == noErr, actual == getpid() else { return false }
        hoggedDeviceID = target
        return true
    }

    public func release() {
        releaseHog()
    }

    public func setSampleRate(_ rate: Double, deviceUID: String) -> Bool {
        guard let target = deviceID(forUID: deviceUID) else { return false }
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyNominalSampleRate,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var value = rate
        let status = AudioObjectSetPropertyData(
            target, &address, 0, nil,
            UInt32(MemoryLayout<Double>.size), &value
        )
        guard status == noErr else { return false }
        // CoreAudio quirk: hardware needs a brief settle window before subsequent IO opens.
        Thread.sleep(forTimeInterval: 0.05)
        return true
    }

    private func releaseHog() {
        guard let target = hoggedDeviceID else { return }
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyHogMode,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var pid: pid_t = -1
        _ = AudioObjectSetPropertyData(
            target, &address, 0, nil,
            UInt32(MemoryLayout<pid_t>.size), &pid
        )
        hoggedDeviceID = nil
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

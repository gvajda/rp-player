import CoreAudio
import Foundation

public actor HogModeController {
    private var hoggedDeviceID: AudioDeviceID?
    internal private(set) var originalSampleRate: Double?

    public init() {}

    public var isHogging: Bool { hoggedDeviceID != nil }

    public func acquire(deviceUID: String) async -> Bool {
        guard let target = deviceID(forUID: deviceUID) else { return false }
        if let current = hoggedDeviceID, current == target { return true }
        if hoggedDeviceID != nil {
            await releaseHog()
        }
        let savedRate = readSampleRate(deviceID: target)
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
        // RP streams are always 44.1 kHz; enforce matching hardware rate to
        // prevent CoreAudio resampling when the device is configured otherwise.
        if !(await setSampleRateInternal(44100.0, deviceID: target, settle: true)) {
            fputs("[HogModeController] setSampleRate(44100) failed — playback may resample\n", stderr)
        }
        hoggedDeviceID = target
        originalSampleRate = savedRate
        return true
    }

    public func release() async {
        await releaseHog()
    }

    public func setSampleRate(_ rate: Double, deviceUID: String) async -> Bool {
        guard let target = deviceID(forUID: deviceUID) else { return false }
        return await setSampleRateInternal(rate, deviceID: target, settle: true)
    }

    private func releaseHog() async {
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
        if let rate = originalSampleRate {
            // No settle sleep on restore — we are releasing, not about to open IO.
            _ = await setSampleRateInternal(rate, deviceID: target, settle: false)
            originalSampleRate = nil
        }
    }

    private func readSampleRate(deviceID: AudioDeviceID) -> Double? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyNominalSampleRate,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var rate: Double = 0
        var size = UInt32(MemoryLayout<Double>.size)
        let status = AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &rate)
        guard status == noErr, rate > 0 else { return nil }
        return rate
    }

    private func setSampleRateInternal(_ rate: Double, deviceID: AudioDeviceID, settle: Bool) async -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyNominalSampleRate,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var value = rate
        let status = AudioObjectSetPropertyData(
            deviceID, &address, 0, nil,
            UInt32(MemoryLayout<Double>.size), &value
        )
        guard status == noErr else { return false }
        if settle {
            // CoreAudio quirk: hardware needs a brief settle window before subsequent IO opens.
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        return true
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

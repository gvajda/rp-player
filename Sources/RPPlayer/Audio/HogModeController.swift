import CoreAudio
import Foundation

public actor HogModeController {
    private var hoggedDeviceID: AudioDeviceID?
    internal private(set) var originalSampleRate: Double?
    private let logger: (any Logging)?

    public init(logger: (any Logging)? = nil) {
        self.logger = logger
    }

    public var isHogging: Bool { hoggedDeviceID != nil }

    public func acquire(deviceUID: String) async -> Bool {
        guard let target = deviceID(forUID: deviceUID) else {
            logger?.warn("hog acquire: device '\(deviceUID)' not found")
            return false
        }
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
        guard setStatus == noErr else {
            logger?.warn("hog acquire: set failed id=\(target) status=\(setStatus)")
            return false
        }
        var size = UInt32(MemoryLayout<pid_t>.size)
        var actual: pid_t = -1
        let getStatus = AudioObjectGetPropertyData(
            target, &address, 0, nil, &size, &actual
        )
        guard getStatus == noErr, actual == getpid() else {
            logger?.warn("hog acquire: verify failed id=\(target) status=\(getStatus) owner=\(actual)")
            return false
        }
        // RP streams are always 44.1 kHz; enforce matching hardware rate to
        // prevent CoreAudio resampling when the device is configured otherwise.
        let rateOK = await setSampleRateInternal(44100.0, deviceID: target, settle: true)
        if !rateOK {
            logger?.warn("hog acquire: setSampleRate(44100) failed id=\(target) — playback may resample")
        }
        hoggedDeviceID = target
        originalSampleRate = savedRate
        logger?.info("hog acquired id=\(target) rateBefore=\(savedRate.map { String($0) } ?? "nil") rateNow=\(readSampleRate(deviceID: target).map { String($0) } ?? "nil")")
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
        let status = AudioObjectSetPropertyData(
            target, &address, 0, nil,
            UInt32(MemoryLayout<pid_t>.size), &pid
        )
        hoggedDeviceID = nil
        var restored = "none"
        if let rate = originalSampleRate {
            // No settle sleep on restore — we are releasing, not about to open IO.
            let ok = await setSampleRateInternal(rate, deviceID: target, settle: false)
            restored = ok ? String(rate) : "failed(\(rate))"
            originalSampleRate = nil
        }
        logger?.info("hog released id=\(target) status=\(status) restoredRate=\(restored)")
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

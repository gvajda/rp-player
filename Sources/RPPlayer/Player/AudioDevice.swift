import CoreAudio
import Foundation

public struct AudioDevice: Equatable, Sendable, Identifiable {
    public let uid: String
    public let name: String
    public let transportType: TransportType

    public init(uid: String, name: String, transportType: TransportType) {
        self.uid = uid
        self.name = name
        self.transportType = transportType
    }

    public var id: String { uid }
}

public enum TransportType: String, Equatable, Sendable, CaseIterable {
    case builtIn
    case usb
    case thunderbolt
    case hdmi
    case bluetooth
    case airplay
    case unknown

    /// Returns whether this transport can plausibly deliver bit-perfect audio.
    /// Bluetooth always re-encodes; AirPlay ditto; Built-in is technically
    /// bit-perfect but never the right choice for an external DAC scenario.
    public var isBitPerfectRecommended: Bool {
        switch self {
        case .usb, .thunderbolt, .hdmi: return true
        case .builtIn, .bluetooth, .airplay, .unknown: return false
        }
    }

    /// Maps a raw CoreAudio `kAudioDevicePropertyTransportType` four-char-code value
    /// to a stable case. BluetoothLE collapses into `.bluetooth` — the picker UI does
    /// not need to distinguish them. Anything not listed maps to `.unknown`.
    public init(rawCoreAudioValue value: UInt32) {
        switch value {
        case kAudioDeviceTransportTypeBuiltIn:                 self = .builtIn
        case kAudioDeviceTransportTypeUSB:                     self = .usb
        case kAudioDeviceTransportTypeThunderbolt:             self = .thunderbolt
        case kAudioDeviceTransportTypeHDMI:                    self = .hdmi
        case kAudioDeviceTransportTypeBluetooth,
             kAudioDeviceTransportTypeBluetoothLE:             self = .bluetooth
        case kAudioDeviceTransportTypeAirPlay:                 self = .airplay
        default:                                               self = .unknown
        }
    }

    public var label: String {
        switch self {
        case .builtIn:      return "Built-in"
        case .usb:          return "USB"
        case .thunderbolt:  return "Thunderbolt"
        case .hdmi:         return "HDMI"
        case .bluetooth:    return "Bluetooth"
        case .airplay:      return "AirPlay"
        case .unknown:      return "Unknown"
        }
    }
}

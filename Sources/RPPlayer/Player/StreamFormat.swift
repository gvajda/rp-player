import Foundation

public struct StreamFormat: Equatable, Sendable {
    public let codec: String
    public let sampleRateHz: Int
    public let kbps: Double?

    public init(codec: String, sampleRateHz: Int, kbps: Double?) {
        self.codec = codec
        self.sampleRateHz = sampleRateHz
        self.kbps = kbps
    }

    public var displayString: String {
        let upper = codec.uppercased()
        switch upper {
        case "FLAC":
            return "FLAC \(Self.formatKHz(sampleRateHz))"
        case "MP3":
            if let kbps { return "MP3 \(Int(kbps.rounded())) kbps" }
            return "MP3 \(Self.formatKHz(sampleRateHz))"
        default:
            return "\(upper) \(sampleRateHz) Hz"
        }
    }

    private static func formatKHz(_ hz: Int) -> String {
        let khz = Double(hz) / 1000.0
        if khz == khz.rounded() {
            return "\(Int(khz)) kHz"
        }
        return String(format: "%.1f kHz", khz)
    }
}

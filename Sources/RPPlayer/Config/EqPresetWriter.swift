import Foundation

public enum EqPresetWriter {
    public static func write(_ preset: EqPreset) -> String {
        var lines: [String] = []
        lines.append("CH: 0")
        lines.append("TYPE: PEQ")
        lines.append("Preamp: \(format(preset.preampDb)) dB")
        for (i, b) in preset.bands.enumerated() {
            let abbr: String
            switch b.type {
            case .peak: abbr = "PK"
            case .lowShelf: abbr = "LS"
            case .highShelf: abbr = "HS"
            }
            let state = b.enabled ? "ON" : "OFF"
            lines.append("Filter \(i + 1): \(state) \(abbr) Fc \(format(b.fcHz)) Hz Gain \(format(b.gainDb)) dB Q \(format(b.q))")
        }
        return lines.joined(separator: "\n") + "\n"
    }

    private static func format(_ v: Double) -> String {
        if v.truncatingRemainder(dividingBy: 1) == 0 { return String(Int(v)) }
        let s = String(format: "%.4f", v)
        var trimmed = s
        while trimmed.hasSuffix("0") { trimmed.removeLast() }
        if trimmed.hasSuffix(".") { trimmed.removeLast() }
        return trimmed
    }
}

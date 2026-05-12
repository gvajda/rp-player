import Foundation

public enum EqChainBuilder {
    public static func build(_ preset: EqPreset) -> String? {
        let enabled = preset.bands.filter(\.enabled)
        if enabled.isEmpty && preset.preampDb == 0 { return nil }
        var parts: [String] = ["volume=volume=\(format(preset.preampDb))dB"]
        for b in enabled {
            switch b.type {
            case .peak:
                parts.append("equalizer=f=\(format(b.fcHz)):t=q:w=\(format(b.q)):g=\(format(b.gainDb))")
            case .lowShelf:
                parts.append("lowshelf=f=\(format(b.fcHz)):t=q:w=\(format(b.q)):g=\(format(b.gainDb))")
            case .highShelf:
                parts.append("highshelf=f=\(format(b.fcHz)):t=q:w=\(format(b.q)):g=\(format(b.gainDb))")
            }
        }
        return "lavfi=[" + parts.joined(separator: ",") + "]"
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

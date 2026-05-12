// Sources/RPPlayer/Config/CrossfeedFilterBuilder.swift
import Foundation

public enum CrossfeedFilterBuilder {
    public static func buildPart(strength: Double, range: Double) -> String {
        let s = format(clamp(strength))
        let r = format(clamp(range))
        return "crossfeed=strength=\(s):range=\(r)"
    }

    private static func clamp(_ v: Double) -> Double {
        if v.isNaN { return 0 }
        return min(1.0, max(0.0, v))
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

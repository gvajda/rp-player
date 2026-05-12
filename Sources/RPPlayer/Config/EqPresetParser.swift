import Foundation

public enum EqPresetError: Error, Equatable, Sendable {
    case warningsNotPermitted(reasons: [String])
    case empty
}

public enum EqPresetParser {
    public static let maxBands = 10

    private static let filterPattern = #"^Filter\s+\d+:\s+(ON|OFF)\s+([A-Z]{2})\s+Fc\s+(\d+(?:\.\d+)?)\s*Hz\s+Gain\s+([+-]?\d+(?:\.\d+)?)\s*dB\s+Q\s+(\d+(?:\.\d+)?)\s*$"#
    private static let preampPattern = #"^Preamp:\s+([+-]?\d+(?:\.\d+)?)\s*dB\s*$"#

    public static func parse(text: String, filename: String) -> Result<EqPreset, EqPresetError> {
        var preampDb: Double = 0
        var bands: [EqBand] = []
        var warnings: [String] = []
        var anySupportedLineSeen = false

        let filterRegex = try! NSRegularExpression(pattern: filterPattern)
        let preampRegex = try! NSRegularExpression(pattern: preampPattern)

        for (index, raw) in text.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
            let line = String(raw).trimmingCharacters(in: .whitespaces)
            if line.isEmpty { continue }

            let range = NSRange(line.startIndex..<line.endIndex, in: line)

            if let m = preampRegex.firstMatch(in: line, range: range) {
                if let r = Range(m.range(at: 1), in: line), let v = Double(line[r]) {
                    preampDb = v
                    anySupportedLineSeen = true
                }
                continue
            }

            if line.hasPrefix("Filter") {
                anySupportedLineSeen = true
                guard let m = filterRegex.firstMatch(in: line, range: range),
                      let stateR = Range(m.range(at: 1), in: line),
                      let typeR = Range(m.range(at: 2), in: line),
                      let fcR = Range(m.range(at: 3), in: line),
                      let gainR = Range(m.range(at: 4), in: line),
                      let qR = Range(m.range(at: 5), in: line),
                      let fc = Double(line[fcR]),
                      let gain = Double(line[gainR]),
                      let q = Double(line[qR])
                else {
                    warnings.append("Malformed Filter line at line \(index + 1): \(line)")
                    continue
                }
                let stateStr = String(line[stateR])
                let typeStr = String(line[typeR])
                if stateStr == "OFF" { continue }
                let mapped: EqBandType?
                switch typeStr {
                case "PK": mapped = .peak
                case "LS": mapped = .lowShelf
                case "HS": mapped = .highShelf
                default:
                    warnings.append("Dropped unsupported filter type \(typeStr) at line \(index + 1)")
                    continue
                }
                bands.append(EqBand(enabled: true, type: mapped!, fcHz: fc, gainDb: gain, q: q))
            }
        }

        if bands.count > maxBands {
            warnings.append("Preset exceeds cap of \(maxBands) bands (got \(bands.count))")
        }

        if !anySupportedLineSeen && bands.isEmpty {
            return .failure(.empty)
        }
        if !warnings.isEmpty {
            return .failure(.warningsNotPermitted(reasons: warnings))
        }
        if bands.isEmpty {
            return .failure(.empty)
        }
        return .success(EqPreset(name: filename, preampDb: preampDb, bands: bands))
    }
}

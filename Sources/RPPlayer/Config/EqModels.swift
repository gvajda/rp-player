import Foundation

public enum EqBandType: String, Codable, Equatable, Sendable {
    case peak
    case lowShelf
    case highShelf
}

public struct EqBand: Codable, Equatable, Sendable {
    public var enabled: Bool
    public var type: EqBandType
    public var fcHz: Double
    public var gainDb: Double
    public var q: Double

    public init(enabled: Bool, type: EqBandType, fcHz: Double, gainDb: Double, q: Double) {
        self.enabled = enabled
        self.type = type
        self.fcHz = fcHz
        self.gainDb = gainDb
        self.q = q
    }
}

public struct EqPreset: Codable, Equatable, Sendable {
    public var name: String?
    public var preampDb: Double
    public var bands: [EqBand]

    public init(name: String?, preampDb: Double, bands: [EqBand]) {
        self.name = name
        self.preampDb = preampDb
        self.bands = bands
    }
}

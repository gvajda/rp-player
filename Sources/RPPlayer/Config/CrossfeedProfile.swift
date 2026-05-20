import Foundation

public enum CrossfeedProfile: String, Codable, Sendable, CaseIterable, Equatable {
    case bs2bDefault = "default"
    case cmoy
    case jmeier
    case custom
}

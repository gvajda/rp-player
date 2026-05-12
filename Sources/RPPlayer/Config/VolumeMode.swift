import Foundation

public enum VolumeMode: String, Codable, Equatable, Sendable, CaseIterable {
    case none
    case replayGain
    case forceMax
}

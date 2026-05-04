import Foundation

public enum MenuBarIconStyle: String, Codable, Sendable, CaseIterable {
    case color     // Original orange-on-black, rounded corners
    case template  // White silhouette, system-tinted (matches typical menu bar icons)
}

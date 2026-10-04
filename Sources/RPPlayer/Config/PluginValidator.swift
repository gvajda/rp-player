import AudioToolbox
import Foundation

public enum PluginValidator {
    public static var hostArchitecture: Int {
        #if arch(arm64)
        NSBundleExecutableArchitectureARM64
        #else
        NSBundleExecutableArchitectureX86_64
        #endif
    }

    private static let effectTypes: Set<OSType> = [kAudioUnitType_Effect, kAudioUnitType_MusicEffect]

    public static func validate(infoPlist: [String: Any], architectures: [Int],
                                existing: [PluginComponent]) -> Result<PluginComponent, PluginStoreError> {
        guard let entries = infoPlist["AudioComponents"] as? [[String: Any]], !entries.isEmpty else {
            return .failure(.notAComponent)
        }
        let parsed = entries.compactMap(parse)
        guard !parsed.isEmpty else { return .failure(.notAComponent) }
        guard let component = parsed.first(where: { effectTypes.contains($0.type) }) else {
            return .failure(.notAnEffect)
        }
        guard architectures.contains(hostArchitecture) else { return .failure(.wrongArchitecture) }
        if let clash = existing.first(where: { $0.sameDescription(as: component) }) {
            return .failure(.duplicate(name: clash.name))
        }
        return .success(component)
    }

    private static func parse(_ entry: [String: Any]) -> PluginComponent? {
        guard let type = (entry["type"] as? String).flatMap(FourCC.code),
              let subtype = (entry["subtype"] as? String).flatMap(FourCC.code),
              let manufacturer = (entry["manufacturer"] as? String).flatMap(FourCC.code),
              let fullName = entry["name"] as? String,
              let factory = entry["factoryFunction"] as? String else { return nil }
        let version = (entry["version"] as? NSNumber)?.uint32Value ?? 0
        let parts = fullName.split(separator: ":", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
        let (maker, name) = parts.count == 2 ? (parts[0], parts[1]) : (FourCC.string(manufacturer), fullName)
        return PluginComponent(type: type, subtype: subtype, manufacturer: manufacturer, name: name,
                               manufacturerName: maker, version: version, factoryFunction: factory)
    }
}

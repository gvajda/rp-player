import AudioToolbox
import Foundation

public struct PluginComponent: Equatable, Sendable {
    public let type: OSType
    public let subtype: OSType
    public let manufacturer: OSType
    public let name: String
    public let manufacturerName: String
    public let version: UInt32
    public let factoryFunction: String

    public var componentDescription: AudioComponentDescription {
        AudioComponentDescription(componentType: type, componentSubType: subtype,
                                  componentManufacturer: manufacturer, componentFlags: 0, componentFlagsMask: 0)
    }

    public var versionString: String { "\(version >> 16).\((version >> 8) & 0xFF).\(version & 0xFF)" }

    func sameDescription(as other: PluginComponent) -> Bool {
        type == other.type && subtype == other.subtype && manufacturer == other.manufacturer
    }
}

public struct ImportedPlugin: Equatable, Sendable, Identifiable {
    public let id: String
    public let bundleURL: URL
    public let component: PluginComponent
}

public enum PluginStoreError: Error, Equatable, Sendable {
    case notAComponent
    case notAnEffect
    case wrongArchitecture
    case duplicate(name: String)
    case notFound
    case ioFailure(String)
}

enum FourCC {
    static func code(_ s: String) -> OSType? {
        let bytes = Array(s.utf8)
        guard bytes.count == 4 else { return nil }
        return bytes.reduce(0) { $0 << 8 | OSType($1) }
    }

    static func string(_ code: OSType) -> String {
        String(decoding: [24, 16, 8, 0].map { UInt8((code >> $0) & 0xFF) }, as: UTF8.self)
    }
}

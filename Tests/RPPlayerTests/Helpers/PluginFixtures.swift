import Foundation

enum PluginFixtures {
    static func componentEntry(type: String = "aufx", subtype: String = "Cn7c", manufacturer: String = "Dthr",
                               name: String = "Airwindows: Console7Channel", version: Int = 0x0001_0203,
                               factory: String = "Console7ChannelFactory") -> [String: Any] {
        ["type": type, "subtype": subtype, "manufacturer": manufacturer, "name": name,
         "version": version, "factoryFunction": factory]
    }

    // Plist-only bundle: enough for validation/import; it has no executable, so it can never be registered.
    static func makeComponent(in dir: URL, named name: String = "Console7Channel",
                              entries: [[String: Any]]? = [componentEntry()]) throws -> URL {
        let bundle = dir.appendingPathComponent("\(name).component")
        let contents = bundle.appendingPathComponent("Contents")
        try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
        var plist: [String: Any] = ["CFBundleIdentifier": "com.example.\(name)", "CFBundlePackageType": "BNDL"]
        if let entries { plist["AudioComponents"] = entries }
        try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
            .write(to: contents.appendingPathComponent("Info.plist"))
        return bundle
    }
}

import Foundation

public enum ConfigPaths {
    public static var applicationSupportRoot: URL {
        let base = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask
        ).first!
        return base.appendingPathComponent("RP Player", isDirectory: true)
    }

    public static var configFile: URL {
        applicationSupportRoot.appendingPathComponent("config.json")
    }

    public static var albumArtCacheDirectory: URL {
        applicationSupportRoot.appendingPathComponent("AlbumArtCache", isDirectory: true)
    }

    public static var logsDirectory: URL {
        let base = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask).first!
        return base
            .appendingPathComponent("Logs", isDirectory: true)
            .appendingPathComponent("RP Player", isDirectory: true)
    }
}

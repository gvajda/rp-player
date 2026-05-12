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

    public static var songFileCacheDirectory: URL {
        applicationSupportRoot.appendingPathComponent("SongFileCache", isDirectory: true)
    }

    public static var eqPresetsDirectory: URL {
        applicationSupportRoot.appendingPathComponent("EqPresets", isDirectory: true)
    }

    public static var logsDirectory: URL {
        applicationSupportRoot.appendingPathComponent("Logs", isDirectory: true)
    }
}

import AudioToolbox
import Foundation

public final class PluginBridge: @unchecked Sendable {
    public static let fileName = "libRPBridge.dylib"

    public let path: String
    private let setUnitFn: @convention(c) (AudioUnit?) -> Void

    private init(path: String, setUnitFn: @escaping @convention(c) (AudioUnit?) -> Void) {
        self.path = path
        self.setUnitFn = setUnitFn
    }

    public static func load(path: String, logger: (any Logging)?) -> PluginBridge? {
        let resolved = URL(fileURLWithPath: path).resolvingSymlinksInPath().path
        // The handle is never dlclose'd: FFmpeg also dlopens this path, and closing our handle could let it dlclose and unload the bridge, losing the current AudioUnit.
        guard let handle = dlopen(resolved, RTLD_NOW | RTLD_LOCAL) else {
            logger?.error("plugin bridge: dlopen \(resolved) failed: \(dlerror().map { String(cString: $0) } ?? "unknown")")
            return nil
        }
        guard let sym = dlsym(handle, "rpbridge_set_unit") else {
            logger?.error("plugin bridge: rpbridge_set_unit missing in \(resolved)")
            return nil
        }
        return PluginBridge(path: resolved, setUnitFn: unsafeBitCast(sym, to: (@convention(c) (AudioUnit?) -> Void).self))
    }

    // The .app ships it in Contents/Frameworks; `swift build` puts it next to the executable.
    public static func defaultPath(bundle: Bundle = .main) -> String? {
        let candidates = [
            bundle.privateFrameworksURL?.appendingPathComponent(fileName),
            bundle.executableURL?.deletingLastPathComponent().appendingPathComponent(fileName),
        ]
        return candidates.compactMap { $0 }
            .first { FileManager.default.fileExists(atPath: $0.path) }?
            .resolvingSymlinksInPath().path
    }

    public func setUnit(_ unit: AudioUnit?) {
        setUnitFn(unit)
    }

    public var filterPart: String? { Self.filterPart(path: path) }

    public static func filterPart(path: String) -> String? {
        // mpv's lavfi=[…] bracket quoting has no escape, so a bracket in the path would end the graph early.
        guard !path.contains("["), !path.contains("]") else { return nil }
        // lavfi unescapes twice: once splitting the graph ([],; are separators), once parsing filter options (: is).
        let value = escape(escape(path, specials: "\\':"), specials: "\\'[],;")
        return "ladspa=file=\(value):p=rpbridge"
    }

    private static func escape(_ s: String, specials: String) -> String {
        var out = ""
        for c in s {
            if specials.contains(c) { out.append("\\") }
            out.append(c)
        }
        return out
    }
}

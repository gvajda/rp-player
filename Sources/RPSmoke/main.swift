import CMpv
import Foundation

@main
struct RPSmoke {
    static func main() {
        let args = Array(CommandLine.arguments.dropFirst())
        if args.first == "--probe-filters" {
            probeFilters()
            return
        }
        let url = args.first ?? "https://stream.radioparadise.com/mp3-320"
        guard let handle = mpv_create() else {
            fputs("mpv_create returned nil\n", stderr)
            exit(1)
        }
        defer { mpv_terminate_destroy(handle) }

        let apiVersion = mpv_client_api_version()
        fputs("libmpv API \((apiVersion >> 16) & 0xFFFF).\(apiVersion & 0xFFFF)\n", stderr)

        // Minimal config: no video, no terminal/input handling. Bit-perfect
        // settings and device pinning land in PlayerEngine (PR 5b).
        let initialOptions: [(String, String)] = [
            ("vid", "no"),
            ("video", "no"),
            ("input-default-bindings", "no"),
            ("input-vo-keyboard", "no"),
            ("terminal", "no"),
            ("idle", "yes"),
            ("audio-display", "no"),
        ]
        for (key, value) in initialOptions {
            let status = mpv_set_option_string(handle, key, value)
            if status < 0 {
                fputs("mpv_set_option_string(\(key)) failed: \(String(cString: mpv_error_string(status)))\n", stderr)
                exit(1)
            }
        }

        let initStatus = mpv_initialize(handle)
        if initStatus < 0 {
            fputs("mpv_initialize failed: \(String(cString: mpv_error_string(initStatus)))\n", stderr)
            exit(1)
        }

        _ = mpv_observe_property(handle, /*reply_userdata*/ 0, "time-pos", MPV_FORMAT_DOUBLE)

        let loadCmd = ["loadfile", url]
        loadCmd.withCStringPointers { cargv in
            let cmdStatus = mpv_command(handle, cargv)
            if cmdStatus < 0 {
                fputs("mpv_command(loadfile) failed: \(String(cString: mpv_error_string(cmdStatus)))\n", stderr)
                exit(1)
            }
        }

        let deadline = Date().addingTimeInterval(6.0)
        while Date() < deadline {
            guard let eventPtr = mpv_wait_event(handle, /*timeout*/ 0.5) else { break }
            let event = eventPtr.pointee
            switch event.event_id {
            case MPV_EVENT_SHUTDOWN:
                fputs("event: shutdown\n", stderr)
                return
            case MPV_EVENT_END_FILE:
                let endPtr = event.data.assumingMemoryBound(to: mpv_event_end_file.self)
                let end = endPtr.pointee
                fputs("event: end-file reason=\(end.reason.rawValue) error=\(end.error)\n", stderr)
                return
            case MPV_EVENT_PROPERTY_CHANGE:
                let propPtr = event.data.assumingMemoryBound(to: mpv_event_property.self)
                let prop = propPtr.pointee
                if prop.format == MPV_FORMAT_DOUBLE,
                   let dataPtr = prop.data?.assumingMemoryBound(to: Double.self) {
                    let pos = dataPtr.pointee
                    let name = String(cString: prop.name)
                    fputs("event: property-change \(name)=\(String(format: "%.2f", pos))\n", stderr)
                }
            default:
                break
            }
        }

        fputs("rpsmoke: time elapsed, exiting cleanly\n", stderr)
    }
}

private func probeFilters() {
    guard let handle = mpv_create() else {
        fputs("mpv_create returned nil\n", stderr)
        exit(1)
    }
    defer { mpv_terminate_destroy(handle) }

    let opts: [(String, String)] = [
        ("vid", "no"), ("video", "no"), ("terminal", "no"),
        ("idle", "yes"), ("audio-display", "no"), ("ao", "null"),
    ]
    for (k, v) in opts {
        _ = mpv_set_option_string(handle, k, v)
    }
    let initStatus = mpv_initialize(handle)
    if initStatus < 0 {
        fputs("mpv_initialize failed: \(String(cString: mpv_error_string(initStatus)))\n", stderr)
        exit(1)
    }

    if let cstr = mpv_get_property_string(handle, "af-list") {
        defer { mpv_free(cstr) }
        let s = String(cString: cstr)
        print("af-list (string form, may be empty if NODE-only):")
        print(s)
        print("---")
    } else {
        print("af-list: mpv_get_property_string returned nil; trying NODE form")
    }

    var node = mpv_node()
    let nodeStatus = mpv_get_property(handle, "af-list", MPV_FORMAT_NODE, &node)
    if nodeStatus >= 0 {
        defer { mpv_free_node_contents(&node) }
        if node.format == MPV_FORMAT_NODE_ARRAY, let list = node.u.list {
            let count = Int(list.pointee.num)
            print("af-list NODE_ARRAY count=\(count)")
            for i in 0..<count {
                let entry = list.pointee.values[i]
                if entry.format == MPV_FORMAT_NODE_MAP, let map = entry.u.list {
                    let mcount = Int(map.pointee.num)
                    for j in 0..<mcount {
                        guard let keyPtr = map.pointee.keys?[j] else { continue }
                        let key = String(cString: keyPtr)
                        if key == "name", map.pointee.values[j].format == MPV_FORMAT_STRING,
                           let v = map.pointee.values[j].u.string {
                            print("  - \(String(cString: v))")
                        }
                    }
                }
            }
        }
    } else {
        fputs("mpv_get_property(af-list, NODE) failed: \(String(cString: mpv_error_string(nodeStatus)))\n", stderr)
    }

    print("---")
    print("set-af probes (lavfi graphs):")
    let probes: [(String, String)] = [
        ("equalizer", "lavfi=[equalizer=f=1000:t=q:w=1:g=0]"),
        ("lowshelf",  "lavfi=[lowshelf=f=100:t=q:w=0.7:g=0]"),
        ("highshelf", "lavfi=[highshelf=f=8000:t=q:w=0.7:g=0]"),
        ("volume",    "lavfi=[volume=0dB]"),
    ]
    for (name, chain) in probes {
        let st = mpv_set_property_string(handle, "af", chain)
        let result = st >= 0 ? "OK" : "FAIL (\(String(cString: mpv_error_string(st))))"
        print("  \(name): \(result)")
    }
    _ = mpv_set_property_string(handle, "af", "")
}

private extension Array where Element == String {
    // strdup-backed argv for `const char**` C APIs; Swift imports that as UnsafeMutablePointer. Pointer scoped to closure.
    func withCStringPointers<R>(_ body: (UnsafeMutablePointer<UnsafePointer<CChar>?>) -> R) -> R {
        let cstrings = self.map { strdup($0)! }
        var argv = cstrings.map { UnsafePointer<CChar>?($0) }
        argv.append(nil)
        defer {
            for s in cstrings { free(s) }
        }
        return argv.withUnsafeMutableBufferPointer { buf in body(buf.baseAddress!) }
    }
}

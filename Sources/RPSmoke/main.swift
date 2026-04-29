import CMpv
import Foundation

@main
struct RPSmoke {
    static func main() {
        let url = CommandLine.arguments.dropFirst().first ?? "https://stream.radioparadise.com/mp3-320"
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
                fputs("event: end-file\n", stderr)
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

private extension Array where Element == String {
    /// Builds a NULL-terminated `argv` for libmpv command APIs that take
    /// `const char**`. Swift imports that as `UnsafeMutablePointer` since C
    /// can't express const-ness on double pointers. Pointer is valid for the
    /// closure body only.
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

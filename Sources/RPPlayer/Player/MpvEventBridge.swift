import CMpv
import Foundation

struct MpvLogLine: Equatable, Sendable {
    let level: String
    let prefix: String
    let text: String
}

enum MpvEventBridge {
    static func logLine(from log: mpv_event_log_message) -> MpvLogLine? {
        guard let levelPtr = log.level, let prefixPtr = log.prefix, let textPtr = log.text else { return nil }
        return MpvLogLine(
            level: String(cString: levelPtr),
            prefix: String(cString: prefixPtr),
            text: String(cString: textPtr).trimmingCharacters(in: .newlines)
        )
    }

    // Only AO-related verbose lines are worth the log volume; everything else at v/info is demux/decoder chatter.
    static func diagnosticText(for line: MpvLogLine) -> String? {
        switch line.level {
        case "warn", "fatal":
            return "mpv[\(line.prefix)] \(line.text)"
        case "info", "v":
            return line.prefix.hasPrefix("ao") ? "mpv[\(line.prefix)] \(line.text)" : nil
        default:
            return nil
        }
    }

    // mpv 0.36 ao_coreaudio start() only warns when AudioOutputUnitStart fails; the
    // core keeps "playing" with time-pos stuck at 0, so this warn is the only signal.
    static func isAudioOutputStartFailure(_ line: MpvLogLine) -> Bool {
        line.level == "warn" && line.prefix == "ao/coreaudio" && line.text.hasPrefix("can't start audio unit")
    }

    static func endReason(from event: mpv_event_end_file) -> PlayerEndReason {
        switch event.reason {
        case MPV_END_FILE_REASON_EOF:      return .eof
        case MPV_END_FILE_REASON_STOP:     return .stopped
        case MPV_END_FILE_REASON_QUIT:     return .quit
        case MPV_END_FILE_REASON_ERROR:    return .error(code: Int(event.error))
        case MPV_END_FILE_REASON_REDIRECT: return .redirect
        default:                           return .unknown(rawValue: event.reason.rawValue)
        }
    }

    static func propertyChange(from prop: mpv_event_property) -> PlayerEvent? {
        guard let namePtr = prop.name else { return nil }
        let name = String(cString: namePtr)
        switch (name, prop.format) {
        case ("time-pos", MPV_FORMAT_INT64):
            guard let dataPtr = prop.data?.assumingMemoryBound(to: Int64.self) else { return nil }
            return .positionUpdate(seconds: Double(dataPtr.pointee))
        default:
            return nil
        }
    }

    static func playerEvent(from event: mpv_event) -> PlayerEvent? {
        switch event.event_id {
        case MPV_EVENT_FILE_LOADED:
            return .fileLoaded
        case MPV_EVENT_START_FILE:
            return .fileStarted
        case MPV_EVENT_END_FILE:
            let endPtr = event.data.assumingMemoryBound(to: mpv_event_end_file.self)
            return .fileEnded(reason: endReason(from: endPtr.pointee))
        case MPV_EVENT_PROPERTY_CHANGE:
            let propPtr = event.data.assumingMemoryBound(to: mpv_event_property.self)
            return propertyChange(from: propPtr.pointee)
        case MPV_EVENT_LOG_MESSAGE:
            let logPtr = event.data.assumingMemoryBound(to: mpv_event_log_message.self)
            guard let line = logLine(from: logPtr.pointee), line.level == "error" else { return nil }
            return .error(message: line.text)
        case MPV_EVENT_SHUTDOWN:
            return .shutdown
        default:
            return nil
        }
    }
}

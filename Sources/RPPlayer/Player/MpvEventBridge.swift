import CMpv
import Foundation

enum MpvEventBridge {
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
        case MPV_EVENT_END_FILE:
            let endPtr = event.data.assumingMemoryBound(to: mpv_event_end_file.self)
            return .fileEnded(reason: endReason(from: endPtr.pointee))
        case MPV_EVENT_PROPERTY_CHANGE:
            let propPtr = event.data.assumingMemoryBound(to: mpv_event_property.self)
            return propertyChange(from: propPtr.pointee)
        case MPV_EVENT_LOG_MESSAGE:
            let logPtr = event.data.assumingMemoryBound(to: mpv_event_log_message.self)
            let log = logPtr.pointee
            if let levelPtr = log.level, String(cString: levelPtr) == "error",
               let textPtr = log.text {
                return .error(message: String(cString: textPtr).trimmingCharacters(in: .newlines))
            }
            return nil
        case MPV_EVENT_SHUTDOWN:
            return .shutdown
        default:
            return nil
        }
    }
}

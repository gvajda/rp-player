import CMpv
import Foundation

public actor MpvPlayerEngine: PlayerEngine {
    private var handle: OpaquePointer?
    private var continuations: [UUID: AsyncStream<PlayerEvent>.Continuation] = [:]
    private var pumpTask: Task<Void, Never>?
    private var isShutdown = false
    private var currentDeviceUID: String?
    private let logger: (any Logging)?

    public init(
        initialDeviceUID: String? = nil,
        initialForceMaxVolume: Bool = false,
        initialApplyReplayGain: Bool = false,
        logger: (any Logging)? = nil
    ) throws {
        guard let h = mpv_create() else {
            throw PlayerEngineError.createFailed
        }

        let baseline: [(String, String)] = [
            ("vid", "no"),
            ("video", "no"),
            ("input-default-bindings", "no"),
            ("input-vo-keyboard", "no"),
            ("terminal", "no"),
            ("idle", "yes"),
            ("audio-display", "no"),
            ("audio-pitch-correction", "no"),
            ("audio-channels", "auto"),
        ]
        for (key, value) in baseline {
            let status = mpv_set_option_string(h, key, value)
            if status < 0 {
                let message = String(cString: mpv_error_string(status))
                mpv_terminate_destroy(h)
                throw PlayerEngineError.setOptionFailed(name: key, code: Int(status), message: message)
            }
        }

        if let uid = initialDeviceUID, !uid.isEmpty {
            let status = mpv_set_option_string(h, "audio-device", "coreaudio/\(uid)")
            if status < 0 {
                let message = String(cString: mpv_error_string(status))
                mpv_terminate_destroy(h)
                throw PlayerEngineError.setOptionFailed(name: "audio-device", code: Int(status), message: message)
            }
        }

        // Force-max-volume pins volume at 100 and caps volume-max at 100 so any
        // future UI slider can't exceed unity gain. ReplayGain "no" matches mpv
        // default; "track" applies per-track gain when the user opts in.
        let initialOptions: [(String, String)] = [
            ("volume", "100"),
            ("volume-max", initialForceMaxVolume ? "100" : "130"),
            ("replaygain", initialApplyReplayGain ? "track" : "no"),
        ]
        for (key, value) in initialOptions {
            let status = mpv_set_option_string(h, key, value)
            if status < 0 {
                let message = String(cString: mpv_error_string(status))
                mpv_terminate_destroy(h)
                throw PlayerEngineError.setOptionFailed(name: key, code: Int(status), message: message)
            }
        }

        let initStatus = mpv_initialize(h)
        if initStatus < 0 {
            let message = String(cString: mpv_error_string(initStatus))
            mpv_terminate_destroy(h)
            throw PlayerEngineError.initializeFailed(code: Int(initStatus), message: message)
        }

        // Subscribe to time-pos so position updates flow through the pump.
        _ = mpv_observe_property(h, /*reply_userdata*/ 0, "time-pos", MPV_FORMAT_DOUBLE)

        // Required for MPV_EVENT_LOG_MESSAGE delivery; without this the bridge's
        // .error(message:) translation path is unreachable.
        _ = mpv_request_log_messages(h, "error")

        self.handle = h
        self.currentDeviceUID = initialDeviceUID
        self.logger = logger
        logger?.debug("MpvPlayerEngine init done; initialDeviceUID=\(initialDeviceUID ?? "nil")")
        // Pump must be started after init returns: Swift 6 nonisolated init can't
        // capture self into a detached Task, but a follow-up actor method can.
        Task { await self.startPump() }
    }

    /// Spawns the detached pump task; idempotent within a single actor lifetime.
    private func startPump() {
        guard pumpTask == nil, !isShutdown, let handle = handle else { return }
        // Wrap the handle in an Unchecked-Sendable box so Swift 6 lets us cross
        // the detached-task boundary; libmpv's client API is thread-safe except
        // for `mpv_wait_event`, and the pump is the only caller.
        let box = HandleBox(handle: handle)
        pumpTask = Task.detached { [weak self] in
            await Self.pump(
                handle: box.handle,
                deliver: { [weak self] event in
                    await self?.deliver(event)
                }
            )
        }
    }

    private struct HandleBox: @unchecked Sendable {
        let handle: OpaquePointer
    }

    public var events: AsyncStream<PlayerEvent> {
        let id = UUID()
        return AsyncStream { continuation in
            if self.isShutdown {
                continuation.finish()
                return
            }
            self.continuations[id] = continuation
            continuation.onTermination = { [weak self] _ in
                Task { [weak self] in await self?.unregister(id: id) }
            }
        }
    }

    /// Runs on a detached background task. Calls `mpv_wait_event` in a loop and
    /// pushes parsed events back to the actor via `deliver`. Exits when the
    /// MPV_EVENT_SHUTDOWN event arrives, or when the task is cancelled and the
    /// next mpv_wait_event returns (shutdown calls mpv_wakeup to break the wait).
    /// Uses a 0.5s timeout so cancellation is observed even if mpv produces no events.
    private static func pump(
        handle: OpaquePointer,
        deliver: @Sendable @escaping (PlayerEvent) async -> Void
    ) async {
        while !Task.isCancelled {
            guard let eventPtr = mpv_wait_event(handle, /*timeout*/ 0.5) else { continue }
            let event = eventPtr.pointee
            if event.event_id == MPV_EVENT_NONE { continue }
            if let translated = MpvEventBridge.playerEvent(from: event) {
                await deliver(translated)
                if case .shutdown = translated { return }
            } else if event.event_id == MPV_EVENT_SHUTDOWN {
                return
            }
        }
    }

    private func deliver(_ event: PlayerEvent) {
        for c in continuations.values { c.yield(event) }
        if case .shutdown = event {
            for c in continuations.values { c.finish() }
            continuations.removeAll()
        }
    }

    public func play(url: URL, startSeconds: Double?) async throws {
        try requireHandle()
        if let start = startSeconds, start > 0 {
            try runCommand(["loadfile", url.absoluteString, "replace", "start=\(start)"])
        } else {
            try runCommand(["loadfile", url.absoluteString])
        }
    }

    public func pause() async throws {
        try requireHandle()
        try setBoolProperty("pause", true)
    }

    public func resume() async throws {
        try requireHandle()
        try setBoolProperty("pause", false)
    }

    public func stop() async throws {
        try requireHandle()
        try runCommand(["stop"])
    }

    public func seek(to seconds: Double) async throws {
        try requireHandle()
        try runCommand(["seek", String(seconds), "absolute"])
    }

    public func setForceMaxVolume(_ enabled: Bool) async throws {
        try requireHandle()
        try setStringProperty("volume", "100")
        try setStringProperty("volume-max", enabled ? "100" : "130")
    }

    public func setApplyReplayGain(_ enabled: Bool) async throws {
        try requireHandle()
        try setStringProperty("replaygain", enabled ? "track" : "no")
    }

    public func setOutputDevice(uid: String?) async throws {
        logger?.debug("engine setOutputDevice(uid: \(uid ?? "nil"))")
        try requireHandle()
        currentDeviceUID = uid
        try applyAudioDevice()
        deliver(.outputDeviceChanged(uid: uid))
    }

    private func applyAudioDevice() throws {
        let value: String
        if let uid = currentDeviceUID, !uid.isEmpty {
            value = "coreaudio/\(uid)"
        } else {
            value = "auto"
        }
        logger?.debug("applyAudioDevice -> \(value)")
        try setStringProperty("audio-device", value)
    }

    func currentAudioDeviceForTesting() -> String? {
        guard let h = handle else { return nil }
        guard let raw = mpv_get_property_string(h, "audio-device") else { return nil }
        defer { mpv_free(raw) }
        return String(cString: raw)
    }

    public func shutdown() async {
        guard !isShutdown else { return }
        isShutdown = true
        // Stop the pump BEFORE destroying the handle: cancel the task and call
        // mpv_wakeup to break the pump out of mpv_wait_event, then drain.
        // If we destroyed the handle first the pump could re-enter mpv_wait_event
        // on a freed pointer (SIGSEGV), and a parked mpv_wait_event(h, -1) call
        // is not woken by mpv_terminate_destroy alone.
        pumpTask?.cancel()
        if let h = handle {
            mpv_wakeup(h)
        }
        await pumpTask?.value
        pumpTask = nil
        if let h = handle {
            mpv_terminate_destroy(h)
        }
        handle = nil
        // Emit a synthetic .shutdown so subscribers see a terminal event before
        // the stream finishes. The pump cannot reliably emit MPV_EVENT_SHUTDOWN
        // here because we cancel and drain it before destroying the handle.
        for c in continuations.values {
            c.yield(.shutdown)
            c.finish()
        }
        continuations.removeAll()
    }

    private func runCommand(_ args: [String]) throws {
        guard let h = handle else { throw PlayerEngineError.alreadyShutdown }
        let cstrings = args.map { strdup($0)! }
        defer { for s in cstrings { free(s) } }
        var argv = cstrings.map { UnsafePointer<CChar>?($0) }
        argv.append(nil)
        let status = argv.withUnsafeMutableBufferPointer { buf -> Int32 in
            mpv_command(h, buf.baseAddress!)
        }
        if status < 0 {
            let message = String(cString: mpv_error_string(status))
            throw PlayerEngineError.commandFailed(name: args.first ?? "<unknown>", code: Int(status), message: message)
        }
    }

    private func setBoolProperty(_ name: String, _ value: Bool) throws {
        guard let h = handle else { throw PlayerEngineError.alreadyShutdown }
        var flag: Int32 = value ? 1 : 0
        let status = mpv_set_property(h, name, MPV_FORMAT_FLAG, &flag)
        if status < 0 {
            let message = String(cString: mpv_error_string(status))
            throw PlayerEngineError.commandFailed(name: name, code: Int(status), message: message)
        }
    }

    private func setStringProperty(_ name: String, _ value: String) throws {
        guard let h = handle else { throw PlayerEngineError.alreadyShutdown }
        let status = mpv_set_property_string(h, name, value)
        if status < 0 {
            let message = String(cString: mpv_error_string(status))
            throw PlayerEngineError.commandFailed(name: name, code: Int(status), message: message)
        }
    }

    private func unregister(id: UUID) { continuations.removeValue(forKey: id) }

    private func requireHandle() throws {
        guard !isShutdown else { throw PlayerEngineError.alreadyShutdown }
    }
}

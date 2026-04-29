import CMpv
import Foundation

public actor LibmpvPlayerEngine: PlayerEngine {
    private var handle: OpaquePointer?
    private var continuations: [UUID: AsyncStream<PlayerEvent>.Continuation] = [:]
    private var pumpTask: Task<Void, Never>?
    private var isShutdown = false

    public init() throws {
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
            ("volume-max", "100"),
        ]
        for (key, value) in baseline {
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

        self.handle = h
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
            await Self.pump(handle: box.handle, deliver: { [weak self] event in
                await self?.deliver(event)
            })
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

    public func play(url: URL) async throws        { try requireHandle(); throw PlayerEngineError.commandFailed(name: "play", code: -100, message: "play not implemented yet") }
    public func pause() async throws               { try requireHandle(); throw PlayerEngineError.commandFailed(name: "pause", code: -100, message: "pause not implemented yet") }
    public func resume() async throws              { try requireHandle(); throw PlayerEngineError.commandFailed(name: "resume", code: -100, message: "resume not implemented yet") }
    public func stop() async throws                { try requireHandle(); throw PlayerEngineError.commandFailed(name: "stop", code: -100, message: "stop not implemented yet") }
    public func seek(to seconds: Double) async throws { try requireHandle(); throw PlayerEngineError.commandFailed(name: "seek", code: -100, message: "seek not implemented yet") }
    public func setHogMode(_ enabled: Bool) async throws { try requireHandle(); throw PlayerEngineError.commandFailed(name: "setHogMode", code: -100, message: "setHogMode not implemented yet") }
    public func setOutputDevice(uid: String?) async throws { try requireHandle(); throw PlayerEngineError.commandFailed(name: "setOutputDevice", code: -100, message: "setOutputDevice not implemented yet") }

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

    private func unregister(id: UUID) { continuations.removeValue(forKey: id) }

    private func requireHandle() throws {
        guard !isShutdown else { throw PlayerEngineError.alreadyShutdown }
    }
}

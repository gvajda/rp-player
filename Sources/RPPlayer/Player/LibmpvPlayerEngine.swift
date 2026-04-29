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

        // Baseline mpv options — match DESIGN.md §6.1: bit-perfect, audio-only,
        // no terminal/input handling. Hog mode and output device come from
        // settings and are applied via setHogMode / setOutputDevice (Task 7).
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

        self.handle = h
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
        if let h = handle {
            mpv_terminate_destroy(h)
        }
        handle = nil
        for c in continuations.values { c.finish() }
        continuations.removeAll()
    }

    private func unregister(id: UUID) { continuations.removeValue(forKey: id) }

    private func requireHandle() throws {
        guard !isShutdown else { throw PlayerEngineError.alreadyShutdown }
    }
}

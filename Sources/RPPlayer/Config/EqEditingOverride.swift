import Foundation

public actor EqEditingOverride {
    private var current: EqPreset?
    private var continuations: [UUID: AsyncStream<EqPreset?>.Continuation] = [:]

    public init() {}

    public func set(_ preset: EqPreset?) {
        current = preset
        for (_, c) in continuations { c.yield(preset) }
    }

    public func snapshot() -> EqPreset? { current }

    public var changes: AsyncStream<EqPreset?> {
        AsyncStream { continuation in
            let id = UUID()
            continuations[id] = continuation
            continuation.onTermination = { @Sendable [weak self] _ in
                Task { await self?.removeContinuation(id) }
            }
        }
    }

    private func removeContinuation(_ id: UUID) {
        continuations.removeValue(forKey: id)
    }
}

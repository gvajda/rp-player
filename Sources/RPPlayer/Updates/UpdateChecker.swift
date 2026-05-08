import Foundation

public protocol UpdateChecking: Sendable, AnyObject {
    func start() async
    func checkNow() async
    func dismissCurrentForButton() async
    var stateUpdates: AsyncStream<UpdateState> { get async }
    var currentState: UpdateState { get async }
}

public final class NoopUpdateChecker: UpdateChecking {
    public init() {}
    public func start() async {}
    public func checkNow() async {}
    public func dismissCurrentForButton() async {}
    public var stateUpdates: AsyncStream<UpdateState> {
        get async {
            AsyncStream { continuation in
                continuation.yield(.unknown)
                continuation.finish()
            }
        }
    }
    public var currentState: UpdateState { get async { .unknown } }
}

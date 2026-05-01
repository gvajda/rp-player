import Foundation

public enum StartupAuthProbe {
    public enum Outcome: Equatable, Sendable {
        case skipped
        case stillValid
        case cleared
        case networkUnavailable
    }

    @MainActor
    @discardableResult
    public static func run(
        api: any RpApiClient,
        auth: any KeychainAuth,
        logger: (any Logging)? = nil,
        onCleared: @MainActor () async -> Void = {}
    ) async -> Outcome {
        logger?.debug("StartupAuthProbe: checking authState")
        guard auth.isLoggedIn else { return .skipped }
        do {
            let state = try await api.authState()
            logger?.debug("StartupAuthProbe: server returned username=\(state.username ?? "nil")")
            if state.username == "anonymous" || state.username == nil {
                await auth.clearCookie()
                await onCleared()
                return .cleared
            }
            return .stillValid
        } catch RpApiError.invalidResponse(statusCode: 401, _) {
            logger?.debug("StartupAuthProbe: 401 response, clearing cookie")
            await auth.clearCookie()
            await onCleared()
            return .cleared
        } catch {
            logger?.debug("StartupAuthProbe: network unavailable: \(error)")
            return .networkUnavailable
        }
    }
}

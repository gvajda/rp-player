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
        onCleared: @MainActor () async -> Void = {}
    ) async -> Outcome {
        guard auth.isLoggedIn else { return .skipped }
        do {
            let state = try await api.authState()
            if state.username == "anonymous" || state.username == nil {
                await auth.clearCookie()
                await onCleared()
                return .cleared
            }
            return .stillValid
        } catch RpApiError.invalidResponse(statusCode: 401, _) {
            await auth.clearCookie()
            await onCleared()
            return .cleared
        } catch {
            return .networkUnavailable
        }
    }
}

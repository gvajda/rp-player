public struct SkipPolicy: Equatable, Sendable {
    public let enabled: Bool
    public let threshold: Int

    public init(enabled: Bool, threshold: Int) {
        self.enabled = enabled
        self.threshold = threshold
    }

    public func shouldSkip(_ userRating: Int) -> Bool {
        enabled && userRating > 0 && userRating < threshold
    }
}

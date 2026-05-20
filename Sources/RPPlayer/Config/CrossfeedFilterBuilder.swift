// Sources/RPPlayer/Config/CrossfeedFilterBuilder.swift
import Foundation

public enum CrossfeedFilterBuilder {
    public static let fcutRange: ClosedRange<Int> = 300...2000
    public static let feedDbRange: ClosedRange<Double> = 1.0...15.0

    public static func buildPart(
        profile: CrossfeedProfile,
        fcut: Int,
        feedDb: Double
    ) -> String {
        switch profile {
        case .custom:
            let f = min(fcutRange.upperBound, max(fcutRange.lowerBound, fcut))
            let dbClamped = min(feedDbRange.upperBound, max(feedDbRange.lowerBound, feedDb))
            let feedInt = Int((dbClamped * 10).rounded())
            return "bs2b=fcut=\(f):feed=\(feedInt)"
        case .bs2bDefault, .cmoy, .jmeier:
            return "bs2b=profile=\(profile.rawValue)"
        }
    }
}

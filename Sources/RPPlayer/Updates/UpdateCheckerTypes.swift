import Foundation

public struct SemVer: Sendable, Equatable, Comparable, Codable {
    public let major: Int
    public let minor: Int
    public let patch: Int

    public init(major: Int, minor: Int, patch: Int) {
        self.major = major
        self.minor = minor
        self.patch = patch
    }

    public static func parse(_ raw: String) -> SemVer? {
        var s = raw
        if s.hasPrefix("v") || s.hasPrefix("V") { s.removeFirst() }
        if let dash = s.firstIndex(of: "-") { s = String(s[..<dash]) }
        let parts = s.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 3,
              let major = Int(parts[0]),
              let minor = Int(parts[1]),
              let patch = Int(parts[2]) else { return nil }
        return SemVer(major: major, minor: minor, patch: patch)
    }

    public static func < (lhs: SemVer, rhs: SemVer) -> Bool {
        if lhs.major != rhs.major { return lhs.major < rhs.major }
        if lhs.minor != rhs.minor { return lhs.minor < rhs.minor }
        return lhs.patch < rhs.patch
    }
}

public struct GitHubReleaseAsset: Sendable, Decodable, Equatable {
    public let name: String
    public let browserDownloadUrl: URL

    enum CodingKeys: String, CodingKey {
        case name
        case browserDownloadUrl = "browser_download_url"
    }
}

public struct GitHubRelease: Sendable, Decodable, Equatable {
    public let tagName: String
    public let body: String
    public let draft: Bool
    public let prerelease: Bool
    public let publishedAt: Date
    public let htmlUrl: URL
    public let assets: [GitHubReleaseAsset]

    enum CodingKeys: String, CodingKey {
        case tagName = "tag_name"
        case body
        case draft
        case prerelease
        case publishedAt = "published_at"
        case htmlUrl = "html_url"
        case assets
    }

    public static func decode(from data: Data) throws -> GitHubRelease {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(GitHubRelease.self, from: data)
    }
}

public struct ReleaseInfo: Sendable, Equatable, Codable {
    public let tagName: String
    public let version: SemVer
    public let publishedAt: Date
    public let body: String
    public let htmlUrl: URL
    public let dmgAssetUrl: URL?

    public init(
        tagName: String,
        version: SemVer,
        publishedAt: Date,
        body: String,
        htmlUrl: URL,
        dmgAssetUrl: URL?
    ) {
        self.tagName = tagName
        self.version = version
        self.publishedAt = publishedAt
        self.body = body
        self.htmlUrl = htmlUrl
        self.dmgAssetUrl = dmgAssetUrl
    }

    public init?(release: GitHubRelease) {
        guard let version = SemVer.parse(release.tagName) else { return nil }
        let dmg = release.assets.first(where: { $0.name.lowercased().hasSuffix(".dmg") })
        self.init(
            tagName: release.tagName,
            version: version,
            publishedAt: release.publishedAt,
            body: release.body,
            htmlUrl: release.htmlUrl,
            dmgAssetUrl: dmg?.browserDownloadUrl
        )
    }
}

public enum UpdateState: Sendable, Equatable {
    case unknown
    case upToDate(checkedAt: Date)
    case available(ReleaseInfo, dismissedFromButton: Bool)
}

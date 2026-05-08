import XCTest
@testable import RPPlayer

final class UpdateCheckerTypesTests: XCTestCase {
    private func loadFixture(_ name: String) throws -> Data {
        let url = try XCTUnwrap(
            Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "Fixtures/Updates")
        )
        return try Data(contentsOf: url)
    }

    func testDecodeMinimalRelease() throws {
        let data = try loadFixture("release_latest")
        let release = try GitHubRelease.decode(from: data)
        XCTAssertEqual(release.tagName, "v0.5.0")
        XCTAssertFalse(release.prerelease)
        XCTAssertFalse(release.draft)
        XCTAssertEqual(release.htmlUrl.absoluteString, "https://github.com/gvajda/rp-player/releases/tag/v0.5.0")
        XCTAssertTrue(release.body.contains("Gapless block transitions"))
        XCTAssertEqual(release.assets.count, 1)
    }

    func testReleaseInfoFromDecode() throws {
        let data = try loadFixture("release_latest")
        let release = try GitHubRelease.decode(from: data)
        let info = try XCTUnwrap(ReleaseInfo(release: release))
        XCTAssertEqual(info.tagName, "v0.5.0")
        XCTAssertEqual(info.version, SemVer(major: 0, minor: 5, patch: 0))
        XCTAssertEqual(
            info.dmgAssetUrl?.absoluteString,
            "https://github.com/gvajda/rp-player/releases/download/v0.5.0/RP%20Player-v0.5.0.dmg"
        )
    }

    func testReleaseInfoNoDmgAsset() throws {
        let data = try loadFixture("release_latest_no_dmg")
        let release = try GitHubRelease.decode(from: data)
        let info = try XCTUnwrap(ReleaseInfo(release: release))
        XCTAssertNil(info.dmgAssetUrl)
    }

    func testReleaseInfoPicksDmgFromMultiAsset() throws {
        let data = try loadFixture("release_latest_multi_asset")
        let release = try GitHubRelease.decode(from: data)
        let info = try XCTUnwrap(ReleaseInfo(release: release))
        XCTAssertEqual(
            info.dmgAssetUrl?.absoluteString,
            "https://github.com/gvajda/rp-player/releases/download/v0.5.0/RP%20Player-v0.5.0.dmg"
        )
    }

    func testReleaseInfoNilWhenTagUnparseable() throws {
        let raw = """
        {"tag_name":"garbage","name":"x","body":"","draft":false,"prerelease":false,
         "published_at":"2026-05-08T10:00:00Z","html_url":"https://example.com","assets":[]}
        """.data(using: .utf8)!
        let release = try GitHubRelease.decode(from: raw)
        XCTAssertNil(ReleaseInfo(release: release))
    }

    func testDecodePrereleaseAndDraftFlags() throws {
        let prereleaseData = try loadFixture("release_latest_prerelease")
        let prerelease = try GitHubRelease.decode(from: prereleaseData)
        XCTAssertTrue(prerelease.prerelease)
        XCTAssertFalse(prerelease.draft)
        XCTAssertEqual(prerelease.tagName, "v0.6.0-beta.1")

        let draftData = try loadFixture("release_latest_draft")
        let draft = try GitHubRelease.decode(from: draftData)
        XCTAssertTrue(draft.draft)
        XCTAssertFalse(draft.prerelease)
        XCTAssertEqual(draft.tagName, "v0.7.0")
    }
}

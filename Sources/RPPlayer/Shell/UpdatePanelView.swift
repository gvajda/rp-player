import SwiftUI

public struct UpdatePanelView: View {
    public let release: ReleaseInfo
    public let onDownloadDmg: (URL) -> Void
    public let onViewFullNotes: (URL) -> Void
    public let onLater: () -> Void

    public init(
        release: ReleaseInfo,
        onDownloadDmg: @escaping (URL) -> Void,
        onViewFullNotes: @escaping (URL) -> Void,
        onLater: @escaping () -> Void
    ) {
        self.release = release
        self.onDownloadDmg = onDownloadDmg
        self.onViewFullNotes = onViewFullNotes
        self.onLater = onLater
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("RP Player \(release.tagName) available")
                .font(.title2)
                .fontWeight(.semibold)

            Text("Released \(relativeDate)")
                .font(.subheadline)
                .foregroundStyle(.secondary)

            Divider()

            ScrollView {
                Text(truncatedNotes)
                    .font(.body)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: 160)

            Text("You can come back to this from the menu → Update Available.")
                .font(.caption)
                .foregroundStyle(.secondary)

            HStack {
                Button("Later", action: onLater)
                Spacer()
                Button("View Full Notes") { onViewFullNotes(release.htmlUrl) }
                if let dmg = release.dmgAssetUrl {
                    Button("Download DMG") { onDownloadDmg(dmg) }
                        .keyboardShortcut(.defaultAction)
                }
            }
        }
        .padding(20)
        .frame(width: 420)
    }

    private var relativeDate: String {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .full
        return f.localizedString(for: release.publishedAt, relativeTo: Date())
    }

    private var truncatedNotes: AttributedString {
        let lines = release.body.split(separator: "\n", omittingEmptySubsequences: false)
        let head = lines.prefix(5).joined(separator: "\n")
        let display: String
        if lines.count > 5 {
            display = head + "\n…"
        } else {
            display = head
        }
        if let attributed = try? AttributedString(markdown: display) {
            return attributed
        }
        return AttributedString(display)
    }
}

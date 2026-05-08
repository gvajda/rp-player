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
                ReleaseNotesView(markdown: release.body)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
                    .padding(.trailing, 4)
            }
            .frame(minHeight: 200, maxHeight: 360)

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
        .frame(width: 460)
    }

    private var relativeDate: String {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .full
        return f.localizedString(for: release.publishedAt, relativeTo: Date())
    }
}

private struct ReleaseNotesView: View {
    let markdown: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(Array(lines.enumerated()), id: \.offset) { _, raw in
                lineView(raw)
            }
        }
    }

    private var lines: [String] {
        markdown.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
    }

    @ViewBuilder
    private func lineView(_ line: String) -> some View {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty {
            Spacer().frame(height: 6)
        } else if trimmed.hasPrefix("### ") {
            Text(inline(String(trimmed.dropFirst(4))))
                .font(.headline)
                .padding(.top, 6)
        } else if trimmed.hasPrefix("## ") {
            Text(inline(String(trimmed.dropFirst(3))))
                .font(.title3)
                .padding(.top, 8)
        } else if trimmed.hasPrefix("# ") {
            Text(inline(String(trimmed.dropFirst(2))))
                .font(.title2)
                .padding(.top, 8)
        } else if let bullet = bulletContent(trimmed) {
            HStack(alignment: .top, spacing: 6) {
                Text("•").foregroundStyle(.secondary)
                Text(inline(bullet))
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.leading, 4)
        } else {
            Text(inline(line))
        }
    }

    private func bulletContent(_ trimmed: String) -> String? {
        if trimmed.hasPrefix("- ") { return String(trimmed.dropFirst(2)) }
        if trimmed.hasPrefix("* ") { return String(trimmed.dropFirst(2)) }
        return nil
    }

    private func inline(_ s: String) -> AttributedString {
        if let a = try? AttributedString(markdown: s) { return a }
        return AttributedString(s)
    }
}

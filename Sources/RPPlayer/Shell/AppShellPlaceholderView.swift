import SwiftUI

struct AppShellPlaceholderView: View {
    static let headline = "RP Player"
    static let subhead = "Menu-bar shell scaffold — playback UI lands in PR 8."

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "music.note")
                .font(.system(size: 48, weight: .regular))
                .foregroundStyle(.secondary)
            Text(Self.headline)
                .font(.title2)
                .fontWeight(.semibold)
            Text(Self.subhead)
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 24)
        }
        .frame(width: 320, height: 420)
        .padding()
    }
}

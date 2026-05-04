import SwiftUI

struct RatingMenu: View {
    let currentRating: Int?
    let isSignedIn: Bool
    let onRate: (Int) -> Void

    var body: some View {
        Menu {
            ForEach(Array((1...10).reversed()), id: \.self) { value in
                Button("\(value)") { onRate(value) }
            }
        } label: {
            Text(label)
                .font(.title3)
                .foregroundStyle(.primary)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .disabled(!isSignedIn)
        .help(isSignedIn ? "Rate this song" : "Sign in to rate")
        .accessibilityLabel(isSignedIn ? "Rate this song" : "Rating (sign in to rate)")
    }

    private var label: String {
        if let r = currentRating { return "★ \(r)" }
        return "☆"
    }
}

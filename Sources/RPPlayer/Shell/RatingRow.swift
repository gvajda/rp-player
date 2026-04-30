import SwiftUI

struct RatingRow: View {
    let currentRating: Int?
    let isSignedIn: Bool
    let onRate: (Int) -> Void

    var body: some View {
        VStack(spacing: 4) {
            HStack(spacing: 6) {
                ForEach(1...10, id: \.self) { value in
                    Button {
                        onRate(value)
                    } label: {
                        Text("\(value)")
                            .font(.caption.monospacedDigit())
                            .frame(width: 22, height: 22)
                            .background(background(for: value))
                            .clipShape(Circle())
                    }
                    .buttonStyle(.plain)
                    .disabled(!isSignedIn)
                    .accessibilityLabel("Rate \(value)")
                }
            }
            if !isSignedIn {
                Text("Sign in to rate")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func background(for value: Int) -> some ShapeStyle {
        if let currentRating, value <= currentRating {
            return AnyShapeStyle(Color.accentColor.opacity(0.6))
        }
        return AnyShapeStyle(Color.secondary.opacity(0.15))
    }
}

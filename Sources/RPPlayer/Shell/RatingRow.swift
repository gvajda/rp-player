import SwiftUI

struct RatingRow: View {
    let currentRating: Int?
    let isSignedIn: Bool
    let onRate: (Int) -> Void

    var body: some View {
        VStack(spacing: 4) {
            HStack(spacing: 0) {
                ForEach(1...10, id: \.self) { value in
                    Button {
                        onRate(value)
                    } label: {
                        Text("\(value)")
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, minHeight: 22)
                            .background(background(for: value))
                    }
                    .buttonStyle(.plain)
                    .disabled(!isSignedIn)
                    .accessibilityLabel("Rate \(value)")
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 4))
            .overlay(
                RoundedRectangle(cornerRadius: 4)
                    .strokeBorder(Color.secondary.opacity(0.25), lineWidth: 0.5)
            )
            if !isSignedIn {
                Text("Sign in to rate")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func background(for value: Int) -> some ShapeStyle {
        if let currentRating, value <= currentRating {
            return AnyShapeStyle(Color.secondary.opacity(0.45))
        }
        return AnyShapeStyle(Color.secondary.opacity(0.1))
    }
}

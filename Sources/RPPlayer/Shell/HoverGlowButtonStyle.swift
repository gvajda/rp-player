import SwiftUI

struct HoverGlow: ViewModifier {
    var tint: Color = .blue
    @State private var hovering = false

    func body(content: Content) -> some View {
        content
            .background(
                // Empty Shape with shadow — shadow renders outward from the
                // rect bounds without bleeding onto the foreground label.
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(Color.clear)
                    .shadow(color: tint.opacity(hovering ? 0.6 : 0), radius: hovering ? 8 : 0)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .stroke(tint.opacity(hovering ? 0.6 : 0), lineWidth: 1.5)
            )
            .onHover { hovering = $0 }
            .animation(.easeInOut(duration: 0.12), value: hovering)
    }
}

extension View {
    func hoverGlow(tint: Color = .blue) -> some View {
        modifier(HoverGlow(tint: tint))
    }
}

/// Looks like `.bordered` but does not change its background on hover or press —
/// the hover affordance is the blue glow + stroke only. Use `filled: true` for
/// the active/selected state (accent blue fill, white text, no hover effect).
struct StableButtonStyle: ButtonStyle {
    var filled: Bool = false

    func makeBody(configuration: Configuration) -> some View {
        StyleBody(configuration: configuration, filled: filled)
    }

    private struct StyleBody: View {
        let configuration: Configuration
        let filled: Bool
        @State private var hovering = false

        var body: some View {
            let bg: Color = filled ? Color.accentColor : Color.gray.opacity(0.18)
            let fg: Color = filled ? .white : .primary
            let glowOn = !filled && hovering
            configuration.label
                .foregroundStyle(fg)
                .padding(.vertical, 4)
                .padding(.horizontal, 10)
                .background(
                    ZStack {
                        // Outer glow casts from this empty rect's edge.
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .fill(Color.clear)
                            .shadow(color: Color.blue.opacity(glowOn ? 0.6 : 0), radius: glowOn ? 8 : 0)
                        // Solid background fill. Constant — never changes on hover.
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .fill(bg)
                    }
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .stroke(Color.blue.opacity(glowOn ? 0.6 : 0), lineWidth: 1.5)
                )
                .scaleEffect(configuration.isPressed ? 0.97 : 1.0)
                .contentShape(Rectangle())
                .onHover { hovering = $0 }
                .animation(.easeInOut(duration: 0.12), value: hovering)
                .animation(.easeInOut(duration: 0.08), value: configuration.isPressed)
        }
    }
}

struct SupportButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        StyleBody(configuration: configuration)
    }

    private struct StyleBody: View {
        let configuration: Configuration
        @State private var hovering = false

        var body: some View {
            configuration.label
                .padding(.vertical, 6)
                .padding(.horizontal, 10)
                .background(
                    ZStack {
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .fill(Color.clear)
                            .shadow(color: Color.blue.opacity(hovering ? 0.6 : 0), radius: hovering ? 8 : 0)
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .fill(Color.blue.opacity(0.18))
                    }
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .stroke(Color.blue.opacity(hovering ? 0.6 : 0), lineWidth: 1.5)
                )
                .scaleEffect(configuration.isPressed ? 0.97 : 1.0)
                .contentShape(Rectangle())
                .onHover { hovering = $0 }
                .animation(.easeInOut(duration: 0.12), value: hovering)
                .animation(.easeInOut(duration: 0.08), value: configuration.isPressed)
        }
    }
}

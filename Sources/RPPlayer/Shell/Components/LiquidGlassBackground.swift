import SwiftUI

struct LiquidGlassBackground: ViewModifier {
    func body(content: Content) -> some View {
        if #available(macOS 26.0, *) {
            content.glassEffect(in: RoundedRectangle(cornerRadius: 10))
        } else {
            content
        }
    }
}

struct LiquidGlassBackgroundIfEnabled: ViewModifier {
    let enabled: Bool
    func body(content: Content) -> some View {
        if enabled {
            content.modifier(LiquidGlassBackground())
        } else {
            content
        }
    }
}

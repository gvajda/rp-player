import SwiftUI

/// Suppresses the default press-state background tint that SwiftUI's plain
/// button style flashes blue on macOS. Used by the popover transport buttons
/// and the gear menu button — neither needs a press-state background.
struct PressOpacityButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .opacity(configuration.isPressed ? 0.55 : 1.0)
            .contentShape(Rectangle())
    }
}

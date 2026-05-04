import SwiftUI

struct AmbientGradientBackground: View {
    let topColor: Color?

    var body: some View {
        LinearGradient(
            colors: [
                topColor ?? Color(nsColor: .windowBackgroundColor),
                (topColor ?? Color(nsColor: .windowBackgroundColor)).opacity(0.4)
            ],
            startPoint: .top,
            endPoint: .bottom
        )
    }
}

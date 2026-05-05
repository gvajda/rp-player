import SwiftUI

struct HoverInfoIcon: View {
    let text: String

    @State private var showTip = false
    @State private var hoverTask: Task<Void, Never>?

    var body: some View {
        Image(systemName: "info.circle")
            .foregroundStyle(.secondary)
            .onHover { isOver in
                hoverTask?.cancel()
                if isOver {
                    hoverTask = Task { @MainActor in
                        try? await Task.sleep(nanoseconds: 300_000_000)
                        if !Task.isCancelled { showTip = true }
                    }
                } else {
                    showTip = false
                }
            }
            .popover(isPresented: $showTip, arrowEdge: .bottom) {
                Text(text)
                    .font(.callout)
                    .padding(10)
                    .frame(maxWidth: 300, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
            }
    }
}

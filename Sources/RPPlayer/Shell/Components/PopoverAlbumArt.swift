import AppKit
import SwiftUI

struct PopoverAlbumArt: View {
    let image: NSImage?
    var size: CGFloat = 342

    var body: some View {
        Group {
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFill()
                    .frame(width: size, height: size)
                    .clipped()
            } else {
                Image(systemName: "music.note")
                    .resizable()
                    .scaledToFit()
                    .padding(80)
                    .foregroundStyle(.secondary)
                    .frame(width: size, height: size)
                    .background(Color(nsColor: .controlBackgroundColor))
            }
        }
    }
}

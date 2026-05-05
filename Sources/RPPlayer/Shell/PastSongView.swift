import AppKit
import SwiftUI

struct PastSongView: View {
    @ObservedObject var viewModel: PastSongViewModel

    private var effectiveLiquidGlassEnabled: Bool {
        LiquidGlassBackground.isAvailable && viewModel.liquidGlassEnabled
    }

    var body: some View {
        VStack(spacing: 0) {
            PopoverAlbumArt(image: viewModel.currentArt)
            VStack(spacing: 12) {
                SongTitleRow(
                    title: viewModel.song.title,
                    artist: viewModel.song.artist,
                    album: viewModel.song.album,
                    year: viewModel.song.year,
                    currentRating: viewModel.currentRating,
                    isSignedIn: viewModel.isSignedIn,
                    onRate: { value in Task { await viewModel.rate(value) } }
                )
            }
            .padding(12)
        }
        .frame(width: 342)
        .background {
            if !effectiveLiquidGlassEnabled {
                AmbientGradientBackground(topColor: viewModel.ambientTopColor)
            }
        }
        .animation(.easeInOut(duration: 0.4), value: viewModel.ambientTopColor)
        .modifier(LiquidGlassBackgroundIfEnabled(enabled: viewModel.liquidGlassEnabled))
        .task { await viewModel.start() }
    }
}


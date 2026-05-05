import AppKit
import SwiftUI

struct PastSongView: View {
    @ObservedObject var viewModel: PastSongViewModel

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
            switch viewModel.popoverStyle {
            case .none:
                Color(nsColor: .windowBackgroundColor)
            case .ambient:
                AmbientGradientBackground(topColor: viewModel.ambientTopColor)
            case .frosty:
                Color.clear
            }
        }
        .animation(.easeInOut(duration: 0.4), value: viewModel.ambientTopColor)
        .task { await viewModel.start() }
    }
}


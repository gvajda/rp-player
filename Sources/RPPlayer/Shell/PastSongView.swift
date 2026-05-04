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
                    currentRating: viewModel.currentRating,
                    isSignedIn: viewModel.isSignedIn,
                    onRate: { value in Task { await viewModel.rate(value) } }
                )
            }
            .padding(12)
        }
        .frame(width: 342)
        .task { await viewModel.start() }
    }
}


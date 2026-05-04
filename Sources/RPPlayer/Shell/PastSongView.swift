import AppKit
import SwiftUI

struct PastSongView: View {
    @ObservedObject var viewModel: PastSongViewModel

    var body: some View {
        VStack(spacing: 0) {
            PopoverAlbumArt(image: viewModel.currentArt)
            VStack(spacing: 12) {
                titleRow
            }
            .padding(12)
        }
        .frame(width: 342)
        .task { await viewModel.start() }
    }

    private var titleRow: some View {
        HStack(alignment: .center, spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text(viewModel.song.title)
                    .font(.headline)
                    .lineLimit(1)
                Text(viewModel.song.artist)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                if let album = viewModel.song.album, !album.isEmpty {
                    Text(album)
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            RatingMenu(
                currentRating: viewModel.currentRating,
                isSignedIn: viewModel.isSignedIn
            ) { value in
                Task { await viewModel.rate(value) }
            }
        }
        .frame(width: 318)
    }
}

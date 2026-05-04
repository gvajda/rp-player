import SwiftUI

struct SongTitleRow: View {
    let title: String
    let artist: String
    let album: String?
    let currentRating: Int?
    let isSignedIn: Bool
    let onRate: (Int) -> Void

    var body: some View {
        HStack(alignment: .center, spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.title3)
                    .lineLimit(1)
                Text(artist)
                    .font(.subheadline)
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                if let album, !album.isEmpty {
                    Text(album)
                        .font(.caption)
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            RatingMenu(
                currentRating: currentRating,
                isSignedIn: isSignedIn,
                onRate: onRate
            )
        }
        .frame(width: 318)
    }
}

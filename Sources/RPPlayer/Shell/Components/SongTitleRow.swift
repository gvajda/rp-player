import SwiftUI

struct SongTitleRow: View {
    let title: String
    let artist: String
    let album: String?
    let year: String?
    let currentRating: Int?
    let isSignedIn: Bool
    let onRate: (Int) -> Void

    private var showAlbumOrYear: Bool {
        let hasAlbum = !(album ?? "").isEmpty
        let hasYear = !(year ?? "").isEmpty
        return hasAlbum || hasYear
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(alignment: .center, spacing: 8) {
                Text(title)
                    .font(.title3)
                    .lineLimit(1)
                Spacer(minLength: 0)
                RatingMenu(
                    currentRating: currentRating,
                    isSignedIn: isSignedIn,
                    onRate: onRate
                )
            }
            Text(artist)
                .font(.subheadline)
                .foregroundStyle(.primary)
                .lineLimit(1)
            if showAlbumOrYear {
                HStack(alignment: .center, spacing: 8) {
                    if let album, !album.isEmpty {
                        Text(album)
                            .font(.caption)
                            .foregroundStyle(.primary)
                            .lineLimit(1)
                    }
                    Spacer(minLength: 0)
                    if let year, !year.isEmpty {
                        Text(year)
                            .font(.caption)
                            .foregroundStyle(.primary)
                            .lineLimit(1)
                    }
                }
            }
        }
        .frame(width: 318)
    }
}

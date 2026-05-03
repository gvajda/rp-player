import AppKit
import SwiftUI

// MARK: - Song card

struct UpcomingSongCardView: View {
    let row: UpcomingSongRow

    var body: some View {
        HStack(spacing: 0) {
            artView
            textArea
        }
        .frame(height: 68)
        .cornerRadius(8)
        .clipped()
    }

    @ViewBuilder
    private var artView: some View {
        if let image = row.art {
            Image(nsImage: image)
                .resizable()
                .scaledToFill()
                .frame(width: 68, height: 68)
                .clipped()
        } else {
            Color(nsColor: .separatorColor)
                .frame(width: 68, height: 68)
        }
    }

    private var textArea: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .center, spacing: 4) {
                Text(row.song.title)
                    .font(.system(size: 11, weight: .semibold))
                    .lineLimit(1)
                    .foregroundStyle(.primary)
                Spacer(minLength: 0)
                if let rating = row.song.userRating,
                   let value = Int(rating), value > 0 {
                    Text("★ \(value)")
                        .font(.system(size: 10))
                        .foregroundStyle(.yellow)
                }
            }
            Text(row.song.artist)
                .font(.system(size: 10))
                .lineLimit(1)
                .foregroundStyle(.secondary)
                .padding(.top, 2)
            if let album = row.song.album, !album.isEmpty {
                Text(album)
                    .font(.system(size: 9))
                    .lineLimit(1)
                    .foregroundStyle(.secondary)
                    .padding(.top, 1)
            }
        }
        .padding(.horizontal, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            LinearGradient(
                colors: [row.ambientColor.opacity(0.28),
                         Color(nsColor: .windowBackgroundColor)],
                startPoint: .leading,
                endPoint: .trailing
            )
        )
    }
}

// MARK: - Skeleton card (loading placeholder)

private struct SkeletonCardView: View {
    let index: Int
    @State private var opacity: Double = 1.0

    var body: some View {
        HStack(spacing: 0) {
            Color(nsColor: .separatorColor)
                .frame(width: 68, height: 68)
            VStack(alignment: .leading, spacing: 5) {
                RoundedRectangle(cornerRadius: 3)
                    .fill(Color(nsColor: .separatorColor))
                    .frame(width: 140, height: 9)
                RoundedRectangle(cornerRadius: 3)
                    .fill(Color(nsColor: .separatorColor))
                    .frame(width: 100, height: 8)
                RoundedRectangle(cornerRadius: 3)
                    .fill(Color(nsColor: .separatorColor))
                    .frame(width: 80, height: 7)
            }
            .padding(.horizontal, 10)
        }
        .frame(height: 68)
        .cornerRadius(8)
        .clipped()
        .opacity(opacity)
        .onAppear {
            withAnimation(
                .easeInOut(duration: 0.9)
                .repeatForever(autoreverses: true)
                .delay(Double(index % 5) * 0.1)
            ) {
                opacity = 0.35
            }
        }
    }
}

// MARK: - Column view

struct UpcomingColumnView: View {
    let column: UpcomingColumn

    var body: some View {
        VStack(alignment: .center, spacing: 6) {
            Text(column.channel.title)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Color.accentColor)
                .frame(maxWidth: .infinity, alignment: .center)
            VStack(spacing: 4) {
                ForEach(column.songs) { row in
                    UpcomingSongCardView(row: row)
                }
            }
        }
        .frame(width: 226)
    }
}

private struct SkeletonColumnView: View {
    let title: String
    let rowCount: Int

    var body: some View {
        VStack(alignment: .center, spacing: 6) {
            Text(title)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Color(nsColor: .tertiaryLabelColor))
                .frame(maxWidth: .infinity, alignment: .center)
            VStack(spacing: 4) {
                ForEach(0..<rowCount, id: \.self) { i in
                    SkeletonCardView(index: i)
                }
            }
        }
        .frame(width: 226)
    }
}

// MARK: - Root view

struct UpcomingProgramView: View {
    @ObservedObject var viewModel: UpcomingProgramViewModel
    let skeletonColumnCount: Int
    let skeletonRowCount: Int

    init(viewModel: UpcomingProgramViewModel,
         skeletonColumnCount: Int = 4,
         skeletonRowCount: Int = 5) {
        self.viewModel = viewModel
        self.skeletonColumnCount = skeletonColumnCount
        self.skeletonRowCount = skeletonRowCount
    }

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            ScrollView(.horizontal, showsIndicators: true) {
                LazyHStack(alignment: .top, spacing: 6) {
                    if viewModel.isLoading {
                        ForEach(0..<skeletonColumnCount, id: \.self) { i in
                            SkeletonColumnView(
                                title: "Loading…",
                                rowCount: skeletonRowCount
                            )
                        }
                    } else {
                        ForEach(viewModel.columns) { column in
                            UpcomingColumnView(column: column)
                        }
                    }
                }
                .padding(10)
            }
        }
        .task { await viewModel.load() }
    }

    private var toolbar: some View {
        HStack(spacing: 8) {
            if let error = viewModel.errorMessage {
                Label(error, systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer()
            if let date = viewModel.lastUpdated {
                Text(date, style: .relative)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            if viewModel.isLoading {
                ProgressView()
                    .controlSize(.small)
            } else {
                Button {
                    Task { await viewModel.refresh() }
                } label: {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 13))
                }
                .buttonStyle(.borderless)
                .help("Refresh")
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .frame(height: 38)
    }
}

import SwiftUI

struct MiniPlayerView: View {
    @ObservedObject var viewModel: MiniPlayerViewModel

    var body: some View {
        VStack(spacing: 12) {
            HStack {
                Spacer()
                Button {
                    viewModel.openSettings()
                } label: {
                    Image(systemName: "gearshape")
                        .font(.system(size: 14, weight: .regular))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Settings")
            }
            artwork
            metadata
            transport
            channelPicker
            RatingRow(
                currentRating: viewModel.currentRating,
                isSignedIn: viewModel.isSignedIn
            ) { value in
                Task { await viewModel.rate(value) }
            }
            if let message = viewModel.errorMessage {
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .multilineTextAlignment(.center)
            }
        }
        .frame(width: 320, height: 540)
        .padding()
        .task { await viewModel.start() }
    }

    private var artwork: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 8)
                .fill(Color.secondary.opacity(0.15))
            if let art = viewModel.currentArt {
                Image(nsImage: art)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: 200, height: 200)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
            } else {
                Image(systemName: "music.quarternote.3")
                    .font(.system(size: 48))
                    .foregroundStyle(.secondary)
            }
        }
        .frame(width: 200, height: 200)
    }

    private var metadata: some View {
        VStack(spacing: 4) {
            Text(viewModel.nowPlaying?.song.title ?? "—")
                .font(.headline)
                .lineLimit(1)
                .multilineTextAlignment(.center)
            Text(viewModel.nowPlaying.map { "\($0.song.artist) · \($0.song.album)" } ?? "Press play to start")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
    }

    private var transport: some View {
        HStack(spacing: 24) {
            Button {
                Task { await viewModel.togglePlayPause() }
            } label: {
                Image(systemName: viewModel.isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: 28))
            }
            .buttonStyle(.plain)
            .accessibilityLabel(viewModel.isPlaying ? "Pause" : "Play")

            Button {
                Task { await viewModel.skipForward() }
            } label: {
                Image(systemName: "forward.fill")
                    .font(.system(size: 24))
            }
            .buttonStyle(.plain)
            .disabled(!viewModel.isPlaying)
            .accessibilityLabel("Skip forward")
        }
    }

    private var channelPicker: some View {
        Picker("Channel", selection: Binding(
            get: { viewModel.selectedChannelId },
            set: { newId in Task { await viewModel.selectChannel(newId) } }
        )) {
            ForEach(viewModel.channels, id: \.chan) { channel in
                if let id = Int(channel.chan) {
                    Text(channel.title).tag(id)
                }
            }
        }
        .pickerStyle(.menu)
        .labelsHidden()
        .frame(maxWidth: .infinity)
    }
}

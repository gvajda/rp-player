import AppKit
import SwiftUI

struct MiniPlayerView: View {
    @ObservedObject var viewModel: MiniPlayerViewModel

    var body: some View {
        VStack(spacing: 0) {
            if let message = viewModel.errorMessage {
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .multilineTextAlignment(.center)
                    .frame(width: 318)
                    .padding(.horizontal, 12)
                    .padding(.top, 12)
            }
            albumArt
            VStack(spacing: 12) {
                titleRow
                progressRow
                channelRow
                transport
            }
            .padding(12)
        }
        .frame(width: 342)
        .task { await viewModel.start() }
    }

    private var albumArt: some View {
        Group {
            if let art = viewModel.currentArt {
                Image(nsImage: art)
                    .resizable()
                    .scaledToFill()
                    .frame(width: 342, height: 342)
                    .clipped()
            } else {
                Image(systemName: "music.note")
                    .resizable()
                    .scaledToFit()
                    .padding(80)
                    .foregroundStyle(.secondary)
                    .frame(width: 342, height: 342)
                    .background(Color(nsColor: .controlBackgroundColor))
            }
        }
    }

    private var titleRow: some View {
        HStack(alignment: .center, spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text(viewModel.nowPlaying?.song.title ?? "—")
                    .font(.headline)
                    .lineLimit(1)
                Text(viewModel.nowPlaying?.song.artist ?? "")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                if let song = viewModel.nowPlaying?.song,
                   let album = song.album,
                   !album.isEmpty {
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

    private var progressRow: some View {
        VStack(spacing: 2) {
            ProgressView(
                value: viewModel.songElapsedSeconds,
                total: max(viewModel.songDurationSeconds, 0.001)
            )
            .progressViewStyle(.linear)
            HStack {
                Text(formatTime(viewModel.songElapsedSeconds))
                Spacer()
                Text(formatTime(viewModel.songDurationSeconds))
            }
            .font(.caption2.monospacedDigit())
            .foregroundStyle(.secondary)
        }
        .frame(width: 318)
    }

    private var channelRow: some View {
        HStack(spacing: 8) {
            HStack(spacing: 4) {
                Spacer()
                if let label = viewModel.currentBitrateLabel {
                    Text(label)
                        .font(.caption2)
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    Text("@")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity)

            channelPicker
                .fixedSize()

            HStack(spacing: 6) {
                Text("RP Player")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                Menu {
                    Button("Settings…") { viewModel.openSettings() }
                    Divider()
                    Button("Quit RP Player") { NSApp.terminate(nil) }
                } label: {
                    Image(systemName: "gearshape")
                        .font(.system(size: 14, weight: .regular))
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .frame(width: 22, height: 22)
                .accessibilityLabel("Settings and Quit")
            }
            .frame(maxWidth: .infinity, alignment: .trailing)
        }
        .frame(width: 318)
    }

    private var channelPicker: some View {
        Picker(selection: Binding(
            get: { viewModel.selectedChannelId },
            set: { newId in Task { await viewModel.selectChannel(newId) } }
        )) {
            ForEach(viewModel.channels, id: \.chan) { channel in
                if let id = Int(channel.chan) {
                    Text(channel.title).tag(id)
                }
            }
        } label: {
            EmptyView()
        }
        .labelsHidden()
        .pickerStyle(.menu)
    }

    private var transport: some View {
        HStack(spacing: 18) {
            Button {
                Task { await viewModel.togglePlayPause() }
            } label: {
                Image(systemName: viewModel.isPlaying ? "pause.circle" : "play.circle")
                    .font(.system(size: 44))
            }
            .buttonStyle(PressOpacityButtonStyle())
            .accessibilityLabel(viewModel.isPlaying ? "Pause" : "Play")

            Button {
                Task { await viewModel.skipForward() }
            } label: {
                Image(systemName: "forward.end.fill")
                    .font(.system(size: 22))
            }
            .buttonStyle(PressOpacityButtonStyle())
            .frame(width: 38, height: 38)
            .disabled(!viewModel.isPlaying)
            .accessibilityLabel("Skip Forward")
        }
    }

    private func formatTime(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "0:00" }
        let s = Int(seconds.rounded(.down))
        return String(format: "%d:%02d", s / 60, s % 60)
    }
}

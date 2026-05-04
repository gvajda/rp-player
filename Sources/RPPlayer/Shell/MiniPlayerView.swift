import AppKit
import SwiftUI

struct MiniPlayerView: View {
    @ObservedObject var viewModel: MiniPlayerViewModel
    @Environment(\.colorScheme) private var colorScheme

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
            PopoverAlbumArt(image: viewModel.currentArt)
            VStack(spacing: 12) {
                SongTitleRow(
                    title: viewModel.nowPlaying?.song.title ?? "—",
                    artist: viewModel.nowPlaying?.song.artist ?? "",
                    album: viewModel.nowPlaying?.song.album,
                    currentRating: viewModel.currentRating,
                    isSignedIn: viewModel.isSignedIn,
                    onRate: { value in Task { await viewModel.rate(value) } }
                )
                progressRow
                transport
                channelRow
            }
            .padding(12)
        }
        .frame(width: 342)
        .background(AmbientGradientBackground(topColor: viewModel.ambientTopColor))
        .animation(.easeInOut(duration: 0.4), value: viewModel.ambientTopColor)
        .task { await viewModel.start() }
    }

    private var progressRow: some View {
        VStack(spacing: 2) {
            if colorScheme == .light && viewModel.ambientTopColor != nil {
                ProgressView(
                    value: viewModel.songElapsedSeconds,
                    total: max(viewModel.songDurationSeconds, 0.001)
                )
                .progressViewStyle(AmbientProgressStyle(fillColor: .black))
            } else {
                ProgressView(
                    value: viewModel.songElapsedSeconds,
                    total: max(viewModel.songDurationSeconds, 0.001)
                )
                .progressViewStyle(.linear)
            }
            HStack {
                Text(formatTime(viewModel.songElapsedSeconds))
                Spacer()
                Text(formatTime(viewModel.songDurationSeconds))
            }
            .font(.caption2.monospacedDigit())
            .foregroundStyle(.primary)
        }
        .frame(width: 318)
    }

    private var channelRow: some View {
        ZStack {
            channelPicker
                .fixedSize()
            HStack {
                Text("RP Player")
                    .font(.caption2)
                    .foregroundStyle(.primary)
                Spacer()
                HStack(spacing: 4) {
                    if let label = viewModel.currentBitrateLabel {
                        Text(label)
                            .font(.caption2)
                            .monospacedDigit()
                            .foregroundStyle(.primary)
                            .lineLimit(1)
                    }
                    Button {
                        let menu = ContextMenuBuilder.build(viewModel: viewModel)
                        if let event = NSApp.currentEvent, let contentView = event.window?.contentView {
                            NSMenu.popUpContextMenu(menu, with: event, for: contentView)
                        }
                    } label: {
                        Image(systemName: "line.3.horizontal")
                            .font(.system(size: 14, weight: .regular))
                            .frame(width: 22, height: 22)
                    }
                    .buttonStyle(PressOpacityButtonStyle())
                    .accessibilityLabel("Menu")
                }
            }
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
        .controlSize(.small)
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

private struct AmbientProgressStyle: ProgressViewStyle {
    let fillColor: Color

    func makeBody(configuration: Configuration) -> some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(fillColor.opacity(0.18))
                    .frame(height: 8)
                Capsule()
                    .fill(fillColor)
                    .frame(
                        width: max(0, geo.size.width * CGFloat(configuration.fractionCompleted ?? 0)),
                        height: 8
                    )
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(height: 20)
    }
}


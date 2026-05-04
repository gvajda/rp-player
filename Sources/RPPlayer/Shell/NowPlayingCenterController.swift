import AppKit
import MediaPlayer

@MainActor
final class NowPlayingCenterController {
    private let coordinator: any PlaybackCoordinator
    private let albumArtCache: any AlbumArtCache

    private var nowPlayingTask: Task<Void, Never>?
    private var stateTask: Task<Void, Never>?
    private var positionTask: Task<Void, Never>?

    private var lastSongDuration: Double = 0
    private var lastPosition: Double = 0
    private var lastCoverPath: String?

    init(coordinator: any PlaybackCoordinator, albumArtCache: any AlbumArtCache) {
        self.coordinator = coordinator
        self.albumArtCache = albumArtCache
    }

    func start() {
        registerCommands()
        let np = coordinator
        nowPlayingTask = Task { [weak self] in
            let stream = await np.nowPlayingUpdates
            for await snapshot in stream {
                await self?.handleNowPlaying(snapshot)
            }
        }
        stateTask = Task { [weak self] in
            let stream = await np.stateUpdates
            for await state in stream {
                await self?.handleState(state)
            }
        }
        positionTask = Task { [weak self] in
            let stream = await np.positionUpdates
            for await pos in stream {
                await self?.handlePosition(pos)
            }
        }
    }

    func stop() {
        nowPlayingTask?.cancel(); nowPlayingTask = nil
        stateTask?.cancel(); stateTask = nil
        positionTask?.cancel(); positionTask = nil
        let center = MPRemoteCommandCenter.shared()
        center.playCommand.removeTarget(nil)
        center.pauseCommand.removeTarget(nil)
        center.togglePlayPauseCommand.removeTarget(nil)
        center.nextTrackCommand.removeTarget(nil)
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
        MPNowPlayingInfoCenter.default().playbackState = .stopped
    }

    private func registerCommands() {
        let center = MPRemoteCommandCenter.shared()
        let coord = coordinator

        center.playCommand.isEnabled = true
        center.pauseCommand.isEnabled = true
        center.togglePlayPauseCommand.isEnabled = true
        center.nextTrackCommand.isEnabled = true
        center.previousTrackCommand.isEnabled = false
        center.seekForwardCommand.isEnabled = false
        center.seekBackwardCommand.isEnabled = false
        center.skipForwardCommand.isEnabled = false
        center.skipBackwardCommand.isEnabled = false
        center.changePlaybackPositionCommand.isEnabled = false

        center.playCommand.addTarget { _ in
            Task { try? await coord.resume() }
            return .success
        }
        center.pauseCommand.addTarget { _ in
            Task { try? await coord.pause() }
            return .success
        }
        center.togglePlayPauseCommand.addTarget { _ in
            Task {
                let state = await coord.currentPlaybackState
                if state == .playing {
                    try? await coord.pause()
                } else {
                    try? await coord.resume()
                }
            }
            return .success
        }
        center.nextTrackCommand.addTarget { _ in
            Task { try? await coord.skipForward() }
            return .success
        }
    }

    private func handleNowPlaying(_ np: NowPlaying) async {
        let song = np.song
        lastSongDuration = max(0, np.songEndSeconds - np.songStartSeconds)
        lastPosition = 0

        var info: [String: Any] = [
            MPMediaItemPropertyTitle: song.title,
            MPMediaItemPropertyArtist: song.artist,
            MPMediaItemPropertyPlaybackDuration: lastSongDuration,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: 0.0,
            MPNowPlayingInfoPropertyPlaybackRate: 1.0,
            MPNowPlayingInfoPropertyMediaType: MPNowPlayingInfoMediaType.audio.rawValue,
            MPNowPlayingInfoPropertyIsLiveStream: false,
        ]
        if let album = song.album {
            info[MPMediaItemPropertyAlbumTitle] = album
        }

        // Reuse cached artwork without redundant disk reads.
        if let cover = song.cover, !cover.isEmpty, cover != lastCoverPath {
            lastCoverPath = cover
            if let image = await albumArtCache.image(for: cover) {
                let size = image.size
                let artwork = MPMediaItemArtwork(boundsSize: size) { _ in image }
                info[MPMediaItemPropertyArtwork] = artwork
            }
        } else if let cover = song.cover, cover == lastCoverPath,
                  let existing = MPNowPlayingInfoCenter.default().nowPlayingInfo?[MPMediaItemPropertyArtwork] {
            info[MPMediaItemPropertyArtwork] = existing
        } else if song.cover == nil {
            lastCoverPath = nil
        }

        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
    }

    private func handleState(_ state: PlaybackState) async {
        let center = MPNowPlayingInfoCenter.default()
        switch state {
        case .playing:
            center.playbackState = .playing
            patchInfo([MPNowPlayingInfoPropertyPlaybackRate: 1.0])
        case .paused:
            center.playbackState = .paused
            patchInfo([MPNowPlayingInfoPropertyPlaybackRate: 0.0])
        case .stopped:
            center.playbackState = .stopped
            center.nowPlayingInfo = nil
            lastCoverPath = nil
        }
    }

    private func handlePosition(_ blockPosition: Double) async {
        // Coordinator emits block-position seconds. NowPlaying carries
        // songStartSeconds; in-song elapsed = blockPosition - songStart.
        guard let np = await coordinator.nowPlaying else { return }
        let elapsed = max(0, blockPosition - np.songStartSeconds)
        lastPosition = elapsed
        patchInfo([MPNowPlayingInfoPropertyElapsedPlaybackTime: elapsed])
    }

    private func patchInfo(_ patch: [String: Any]) {
        var info = MPNowPlayingInfoCenter.default().nowPlayingInfo ?? [:]
        for (k, v) in patch { info[k] = v }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
    }
}

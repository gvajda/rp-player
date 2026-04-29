import Foundation

public protocol PlaybackCoordinator: Sendable {
    var nowPlaying: NowPlaying? { get async }
    var nowPlayingUpdates: AsyncStream<NowPlaying> { get async }

    func play(channelId: Int) async throws
    func pause() async throws
    func resume() async throws
    func stop() async throws
    func skipForward() async throws
    func changeChannel(to channelId: Int) async throws
    func shutdown() async
}

import Foundation
@testable import RPPlayer

struct UpdateHistoryArgs: Sendable, Equatable {
    let songId: String
    let chan: Int
    let event: String
    let audioType: String
    let sliceNum: String?
    let playPositionMillis: Int
    let playtimeSecs: Int
    let pauseFlag: Bool
}

struct UpdatePauseArgs: Sendable, Equatable {
    let songId: String
    let chan: Int
    let event: String
    let audioType: String
    let sliceNum: String?
    let pauseDurationMillis: Int
    let playtimeSecs: Int
}

actor MockRpApiClient: RpApiClient {
    enum Call: Sendable, Equatable {
        case listChannels
        case play(channel: Int, bitrate: Int, event: Int, action: PlayAction, audioType: String?, episodeId: Int?, sliceNum: String?)
        case info(songId: Int)
        case rate(songId: Int, rating: Int)
        case authState
    }

    private(set) var calls: [Call] = []
    private(set) var playCancellations: Int = 0
    var updateHistoryCalls: [UpdateHistoryArgs] = []
    var updatePauseCalls: [UpdatePauseArgs] = []

    var playDelayNanos: UInt64 = 0
    var blockResponses: [GetBlock] = []
    var listChannelsResponse: [Channel] = []
    var listChannelsError: Error?
    var infoResponse: SongInfo?
    var ratingResponse: Rating = Rating(status: "ok", songId: nil, userId: nil, userRating: nil)
    var rateError: Error?
    var authStateResponse: Auth = Auth(userId: nil, postOk: nil, username: nil, level: nil,
                                        countryCode: nil, avatar: nil, privmsgNew: nil, status: nil)
    var authStateError: Error?

    func setBlockResponses(_ responses: [GetBlock]) {
        self.blockResponses = responses
    }

    func setPlayDelay(nanos: UInt64) {
        self.playDelayNanos = nanos
    }

    func setInfoResponse(_ response: SongInfo) {
        self.infoResponse = response
    }

    func setListChannelsResponse(_ response: [Channel]) {
        self.listChannelsResponse = response
        self.listChannelsError = nil
    }

    func setListChannelsError(_ error: Error) {
        self.listChannelsError = error
    }

    func setRateError(_ error: Error) {
        self.rateError = error
    }

    func setAuthStateResponse(_ response: Auth) {
        self.authStateResponse = response
        self.authStateError = nil
    }

    func setAuthStateError(_ error: Error) {
        self.authStateError = error
    }

    func listChannels() async throws -> [Channel] {
        calls.append(.listChannels)
        if let error = listChannelsError { throw error }
        return listChannelsResponse
    }

    func play(channel: Int, bitrate: Int, event: Int, action: PlayAction,
              audioType: String?, episodeId: Int?, sliceNum: String?) async throws -> GetBlock {
        calls.append(.play(channel: channel, bitrate: bitrate, event: event, action: action,
                           audioType: audioType, episodeId: episodeId, sliceNum: sliceNum))
        if playDelayNanos > 0 {
            do {
                try await Task.sleep(nanoseconds: playDelayNanos)
            } catch {
                playCancellations += 1
                throw error
            }
        }
        guard !blockResponses.isEmpty else {
            throw RpApiError.network(URLError(.unknown))
        }
        return blockResponses.removeFirst()
    }

    func info(songId: Int) async throws -> SongInfo {
        calls.append(.info(songId: songId))
        if let r = infoResponse { return r }
        throw RpApiError.network(URLError(.unknown))
    }

    func rate(songId: Int, rating: Int) async throws -> Rating {
        calls.append(.rate(songId: songId, rating: rating))
        if let error = rateError { throw error }
        return ratingResponse
    }

    func authState() async throws -> Auth {
        calls.append(.authState)
        if let error = authStateError { throw error }
        return authStateResponse
    }

    func updateHistory(
        songId: String, chan: Int, event: String, audioType: String,
        sliceNum: String?, playPositionMillis: Int, playtimeSecs: Int,
        pauseFlag: Bool
    ) async throws {
        updateHistoryCalls.append(UpdateHistoryArgs(
            songId: songId, chan: chan, event: event, audioType: audioType,
            sliceNum: sliceNum, playPositionMillis: playPositionMillis,
            playtimeSecs: playtimeSecs, pauseFlag: pauseFlag
        ))
    }

    func updatePause(
        songId: String, chan: Int, event: String, audioType: String,
        sliceNum: String?, pauseDurationMillis: Int, playtimeSecs: Int
    ) async throws {
        updatePauseCalls.append(UpdatePauseArgs(
            songId: songId, chan: chan, event: event, audioType: audioType,
            sliceNum: sliceNum, pauseDurationMillis: pauseDurationMillis,
            playtimeSecs: playtimeSecs
        ))
    }
}

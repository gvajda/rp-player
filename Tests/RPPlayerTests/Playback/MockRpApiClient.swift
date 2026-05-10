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
    let playPositionMillis: Int
    let playtimeSecs: Int
}

actor MockRpApiClient: RpApiClient {
    enum Call: Sendable, Equatable {
        case listChannels
        case gapless(channel: Int, bitrate: Int, numSongs: Int)
        case info(songId: Int)
        case rate(songId: Int, rating: Int)
        case authState
    }

    private(set) var calls: [Call] = []
    var updateHistoryCalls: [UpdateHistoryArgs] = []
    var updatePauseCalls: [UpdatePauseArgs] = []

    var gaplessResponse: GaplessResponse?
    var gaplessResponses: [GaplessResponse] = []
    var gaplessByChannel: [Int: GaplessResponse] = [:]
    var gaplessError: Error?
    var gaplessDelayNanos: UInt64 = 0
    var listChannelsResponse: [Channel] = []
    var listChannelsError: Error?
    var infoResponse: SongInfo?
    var ratingResponse: Rating = Rating(status: "ok", songId: nil, userId: nil, userRating: nil)
    var rateError: Error?
    var authStateResponse: Auth = Auth(userId: nil, postOk: nil, username: nil, level: nil,
                                        countryCode: nil, avatar: nil, privmsgNew: nil, status: nil)
    var authStateError: Error?

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

    func gapless(channel: Int, bitrate: Int, numSongs: Int) async throws -> GaplessResponse {
        calls.append(.gapless(channel: channel, bitrate: bitrate, numSongs: numSongs))
        if gaplessDelayNanos > 0 {
            try await Task.sleep(nanoseconds: gaplessDelayNanos)
        }
        if let error = gaplessError { throw error }
        if let r = gaplessByChannel[channel] { return r }
        if !gaplessResponses.isEmpty { return gaplessResponses.removeFirst() }
        if let r = gaplessResponse { return r }
        throw RpApiError.network(URLError(.unknown))
    }

    func setGaplessByChannel(_ map: [Int: GaplessResponse]) {
        self.gaplessByChannel = map
        self.gaplessError = nil
    }

    func setGaplessResponse(_ response: GaplessResponse) {
        self.gaplessResponse = response
        self.gaplessError = nil
    }

    func setGaplessResponses(_ responses: [GaplessResponse]) {
        self.gaplessResponses = responses
        self.gaplessError = nil
    }

    func setGaplessError(_ error: Error) {
        self.gaplessError = error
    }

    func setGaplessDelay(nanos: UInt64) {
        self.gaplessDelayNanos = nanos
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
        sliceNum: String?, playPositionMillis: Int, playtimeSecs: Int
    ) async throws {
        updatePauseCalls.append(UpdatePauseArgs(
            songId: songId, chan: chan, event: event, audioType: audioType,
            sliceNum: sliceNum, playPositionMillis: playPositionMillis,
            playtimeSecs: playtimeSecs
        ))
    }
}

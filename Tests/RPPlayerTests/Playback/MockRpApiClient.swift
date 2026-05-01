import Foundation
@testable import RPPlayer

actor MockRpApiClient: RpApiClient {
    enum Call: Sendable, Equatable {
        case listChannels
        case getBlock(channel: Int, bitrate: Int, info: Bool, event: Int?)
        case nowPlaying(channel: Int)
        case info(songId: Int)
        case rate(songId: Int, rating: Int)
        case authState
    }

    private(set) var calls: [Call] = []

    var blockResponses: [GetBlock] = []
    var nowPlayingResponse: NowPlayingEntry?
    var nowPlayingError: Error?
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

    func setNowPlayingResponse(_ entry: NowPlayingEntry) {
        self.nowPlayingResponse = entry
        self.nowPlayingError = nil
    }

    func setNowPlayingError(_ error: Error) {
        self.nowPlayingError = error
        self.nowPlayingResponse = nil
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

    func getBlock(channel: Int, bitrate: Int, info: Bool, event: Int?) async throws -> GetBlock {
        calls.append(.getBlock(channel: channel, bitrate: bitrate, info: info, event: event))
        guard !blockResponses.isEmpty else {
            throw RpApiError.network(URLError(.unknown))
        }
        return blockResponses.removeFirst()
    }

    func nowPlaying(channel: Int) async throws -> NowPlayingEntry {
        calls.append(.nowPlaying(channel: channel))
        if let error = nowPlayingError { throw error }
        if let entry = nowPlayingResponse { return entry }
        throw RpApiError.network(URLError(.unknown))
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
}

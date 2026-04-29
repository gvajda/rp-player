import Foundation
@testable import RPPlayer

actor MockRpApiClient: RpApiClient {
    enum Call: Sendable, Equatable {
        case listChannels
        case getBlock(channel: Int, bitrate: Int, info: Bool)
        case info(songId: Int)
        case rate(songId: Int, rating: Int)
        case authState
    }

    private(set) var calls: [Call] = []

    var blockResponses: [GetBlock] = []
    var listChannelsResponse: [Channel] = []
    var infoResponse: SongInfo?
    var ratingResponse: Rating = Rating(status: "ok", songId: nil, userId: nil, userRating: nil)
    var authStateResponse: Auth = Auth(userId: nil, postOk: nil, username: nil, level: nil,
                                        countryCode: nil, avatar: nil, privmsgNew: nil, status: nil)

    func setBlockResponses(_ responses: [GetBlock]) {
        self.blockResponses = responses
    }

    func setInfoResponse(_ response: SongInfo) {
        self.infoResponse = response
    }

    func listChannels() async throws -> [Channel] {
        calls.append(.listChannels)
        return listChannelsResponse
    }

    func getBlock(channel: Int, bitrate: Int, info: Bool) async throws -> GetBlock {
        calls.append(.getBlock(channel: channel, bitrate: bitrate, info: info))
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
        return ratingResponse
    }

    func authState() async throws -> Auth {
        calls.append(.authState)
        return authStateResponse
    }
}

import Foundation

public protocol RpApiClient: Sendable {
    func listChannels() async throws -> [Channel]
    func getBlock(channel: Int, bitrate: Int, info: Bool) async throws -> GetBlock
    func info(songId: Int) async throws -> SongInfo
    func rate(songId: Int, rating: Int) async throws -> Rating
    func authState() async throws -> Auth
}

public struct LiveRpApiClient: RpApiClient {
    public static let defaultBaseURL = URL(string: "https://api.radioparadise.com/")!

    private let baseURL: URL
    private let session: URLSession
    private let cookieProvider: any CookieProvider
    private let logger: any Logging

    public init(
        baseURL: URL = LiveRpApiClient.defaultBaseURL,
        session: URLSession = .shared,
        cookieProvider: any CookieProvider,
        logger: any Logging
    ) {
        self.baseURL = baseURL
        self.session = session
        self.cookieProvider = cookieProvider
        self.logger = logger
    }

    public func listChannels() async throws -> [Channel] {
        try await get(path: "api/list_chan", query: [:])
    }

    public func getBlock(channel: Int, bitrate: Int, info: Bool) async throws -> GetBlock {
        try await get(path: "api/get_block", query: [
            "chan": String(channel),
            "bitrate": String(bitrate),
            "info": info ? "true" : "false",
        ])
    }

    public func info(songId: Int) async throws -> SongInfo {
        try await get(path: "api/info", query: ["song_id": String(songId)])
    }

    public func rate(songId: Int, rating: Int) async throws -> Rating {
        try await get(path: "api/rating", query: [
            "song_id": String(songId),
            "rating": String(rating),
        ])
    }

    public func authState() async throws -> Auth {
        try await get(path: "api/auth-state", query: [:])
    }

    private func get<T: Decodable>(path: String, query: [String: String]) async throws -> T {
        guard var components = URLComponents(url: baseURL.appendingPathComponent(path), resolvingAgainstBaseURL: false) else {
            throw RpApiError.network(URLError(.badURL))
        }
        if !query.isEmpty {
            // Sort keys for deterministic URLs (helps tests register stubs predictably).
            components.queryItems = query.sorted(by: { $0.key < $1.key }).map { URLQueryItem(name: $0.key, value: $0.value) }
        }
        guard let url = components.url else {
            throw RpApiError.network(URLError(.badURL))
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        if let cookie = await cookieProvider.currentCookie() {
            request.setValue(cookie, forHTTPHeaderField: "Cookie")
        }

        logger.debug("GET \(url.absoluteString)")

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch let error as URLError {
            logger.error("Network failure for \(url.absoluteString): \(error)")
            throw RpApiError.network(error)
        } catch {
            logger.error("Unknown network error for \(url.absoluteString): \(error)")
            throw RpApiError.underlying(error)
        }

        guard let http = response as? HTTPURLResponse else {
            throw RpApiError.invalidResponse(statusCode: -1, body: data)
        }
        guard (200..<300).contains(http.statusCode) else {
            logger.error("HTTP \(http.statusCode) for \(url.absoluteString)")
            throw RpApiError.invalidResponse(statusCode: http.statusCode, body: data)
        }

        do {
            return try JSONDecoder.rpDecoder.decode(T.self, from: data)
        } catch let error as DecodingError {
            logger.error("Decode failure for \(url.absoluteString): \(error)")
            throw RpApiError.decoding(error)
        } catch {
            throw RpApiError.underlying(error)
        }
    }
}

extension JSONDecoder {
    /// Shared decoder used for all RP API responses. snake_case → camelCase.
    static let rpDecoder: JSONDecoder = {
        let d = JSONDecoder()
        d.keyDecodingStrategy = .convertFromSnakeCase
        return d
    }()
}

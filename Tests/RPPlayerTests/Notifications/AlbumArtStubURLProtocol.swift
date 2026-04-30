import Foundation

final class AlbumArtStubURLProtocol: URLProtocol {
    nonisolated(unsafe) static var responses: [URL: (Data, HTTPURLResponse)] = [:]
    nonisolated(unsafe) static var failures: [URL: Error] = [:]

    static func reset() {
        responses = [:]
        failures = [:]
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL))
            return
        }
        if let error = Self.failures[url] {
            client?.urlProtocol(self, didFailWithError: error)
            return
        }
        if let (data, response) = Self.responses[url] {
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
            return
        }
        client?.urlProtocol(self, didFailWithError: URLError(.fileDoesNotExist))
    }

    override func stopLoading() {}
}

extension AlbumArtStubURLProtocol {
    static func register(url: URL, data: Data, statusCode: Int = 200) {
        let response = HTTPURLResponse(
            url: url, statusCode: statusCode, httpVersion: nil, headerFields: nil
        )!
        responses[url] = (data, response)
    }

    static func registerFailure(url: URL, error: Error) {
        failures[url] = error
    }
}

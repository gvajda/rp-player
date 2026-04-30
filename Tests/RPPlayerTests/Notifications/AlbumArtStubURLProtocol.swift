import Foundation

final class AlbumArtStubURLProtocol: URLProtocol {
    nonisolated(unsafe) private static var responses: [URL: (Data, HTTPURLResponse)] = [:]
    nonisolated(unsafe) private static var failures: [URL: Error] = [:]
    private static let lock = NSLock()

    static func reset() {
        lock.lock(); defer { lock.unlock() }
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
        Self.lock.lock()
        let failure = Self.failures[url]
        let response = Self.responses[url]
        Self.lock.unlock()
        if let error = failure {
            client?.urlProtocol(self, didFailWithError: error)
            return
        }
        if let (data, response) = response {
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
        lock.lock(); defer { lock.unlock() }
        responses[url] = (data, response)
    }

    static func registerFailure(url: URL, error: Error) {
        lock.lock(); defer { lock.unlock() }
        failures[url] = error
    }
}

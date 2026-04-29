import Foundation

/// URLProtocol subclass that serves canned `(Data, HTTPURLResponse)` pairs
/// keyed by request URL. Use via `StubURLProtocol.register(url:body:status:)`
/// then plug `StubURLProtocol.makeSession()` into the system under test.
///
/// Stub state is held in a global `static` keyed only by URL. Tests are
/// expected to call `setUp { StubURLProtocol.reset() }` and `tearDown { ... }`
/// to avoid leakage. If multiple test classes ever use this concurrently
/// (parallel test execution), they will race on the shared registry —
/// add per-session keying before that scenario lands.
final class StubURLProtocol: URLProtocol {
    /// Stub registry. Synchronised via `lock` because URLProtocol callbacks
    /// can come from any thread under URLSession's internal queues.
    nonisolated(unsafe) private static var stubs: [URL: (Data, HTTPURLResponse)] = [:]
    private static let lock = NSLock()

    static func register(url: URL, body: Data, status: Int = 200, headers: [String: String] = [:]) {
        var allHeaders = headers
        if allHeaders["Content-Type"] == nil { allHeaders["Content-Type"] = "application/json" }
        let response = HTTPURLResponse(
            url: url,
            statusCode: status,
            httpVersion: "HTTP/1.1",
            headerFields: allHeaders
        )!
        lock.lock(); defer { lock.unlock() }
        stubs[url] = (body, response)
    }

    static func reset() {
        lock.lock(); defer { lock.unlock() }
        stubs.removeAll()
    }

    static func makeSession() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubURLProtocol.self]
        return URLSession(configuration: config)
    }

    override class func canInit(with request: URLRequest) -> Bool {
        guard let url = request.url else { return false }
        lock.lock(); defer { lock.unlock() }
        return stubs[url] != nil
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL))
            return
        }
        Self.lock.lock()
        let entry = Self.stubs[url]
        Self.lock.unlock()
        guard let (data, response) = entry else {
            client?.urlProtocol(self, didFailWithError: URLError(.fileDoesNotExist))
            return
        }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

import Foundation

public enum RpApiError: Error, Sendable {
    /// Underlying network failure (connectivity, TLS, timeout).
    case network(URLError)
    /// Server returned a non-2xx status. `body` is the response payload, useful for diagnostics.
    case invalidResponse(statusCode: Int, body: Data)
    /// JSON could not be decoded into the expected model.
    case decoding(DecodingError)
    /// Underlying error of an unexpected type (catch-all).
    case underlying(Error)
}

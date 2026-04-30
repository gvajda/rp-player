import AppKit
import XCTest
@testable import RPPlayer

final class AlbumArtCacheTests: XCTestCase {
    private var tempDirectory: URL!
    private var sut: LiveAlbumArtCache!
    private var session: URLSession!
    private var logger: AppLogger!
    private let baseURL = URL(string: "https://test.local/")!

    override func setUp() async throws {
        tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("album-art-cache-tests-\(UUID().uuidString)")
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [AlbumArtStubURLProtocol.self]
        session = URLSession(configuration: config)
        logger = AppLogger(category: "test")
        AlbumArtStubURLProtocol.reset()
        sut = try LiveAlbumArtCache(
            directory: tempDirectory,
            baseURL: baseURL,
            session: session,
            logger: logger,
            maxFiles: 3,
            maxBytes: 1024 * 1024
        )
    }

    override func tearDown() async throws {
        AlbumArtStubURLProtocol.reset()
        try? FileManager.default.removeItem(at: tempDirectory)
    }

    func testCacheMissDownloadsAndReturnsImage() async throws {
        let cover = "covers/l/test.jpg"
        let url = URL(string: cover, relativeTo: baseURL)!.absoluteURL
        let png = Self.makeOnePixelPNG()
        AlbumArtStubURLProtocol.register(url: url, data: png)

        let image = await sut.image(for: cover)

        XCTAssertNotNil(image)
        XCTAssertGreaterThan(image?.size.width ?? 0, 0)
    }

    func testCacheHitReturnsImageWithoutSecondNetworkCall() async throws {
        let cover = "covers/l/test.jpg"
        let url = URL(string: cover, relativeTo: baseURL)!.absoluteURL
        AlbumArtStubURLProtocol.register(url: url, data: Self.makeOnePixelPNG())

        _ = await sut.image(for: cover)
        AlbumArtStubURLProtocol.reset()

        let image = await sut.image(for: cover)
        XCTAssertNotNil(image, "Expected on-disk hit to succeed even after stub was cleared")
    }

    func testNetworkFailureReturnsNil() async throws {
        let cover = "covers/l/missing.jpg"
        let url = URL(string: cover, relativeTo: baseURL)!.absoluteURL
        AlbumArtStubURLProtocol.registerFailure(url: url, error: URLError(.notConnectedToInternet))

        let image = await sut.image(for: cover)
        XCTAssertNil(image)
    }

    func testNon200ResponseReturnsNil() async throws {
        let cover = "covers/l/forbidden.jpg"
        let url = URL(string: cover, relativeTo: baseURL)!.absoluteURL
        AlbumArtStubURLProtocol.register(url: url, data: Data(), statusCode: 403)

        let image = await sut.image(for: cover)
        XCTAssertNil(image)
    }

    func testEvictsOldestWhenMaxFilesExceeded() async throws {
        for i in 0..<5 {
            let cover = "covers/l/img-\(i).jpg"
            let url = URL(string: cover, relativeTo: baseURL)!.absoluteURL
            AlbumArtStubURLProtocol.register(url: url, data: Self.makeOnePixelPNG())
            _ = await sut.image(for: cover)
        }
        let entries = try FileManager.default.contentsOfDirectory(
            at: tempDirectory, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]
        )
        XCTAssertLessThanOrEqual(entries.count, 3)
    }

    func testConcurrentRequestsForSameCoverShareDownload() async throws {
        let cover = "covers/l/concurrent.jpg"
        let url = URL(string: cover, relativeTo: baseURL)!.absoluteURL
        AlbumArtStubURLProtocol.register(url: url, data: Self.makeOnePixelPNG())

        let cache = sut!
        async let a = cache.image(for: cover)
        async let b = cache.image(for: cover)
        let (resultA, resultB) = await (a, b)

        XCTAssertNotNil(resultA)
        XCTAssertNotNil(resultB)
    }

    private static func makeOnePixelPNG() -> Data {
        let image = NSImage(size: NSSize(width: 1, height: 1))
        image.lockFocus()
        NSColor.red.setFill()
        NSRect(x: 0, y: 0, width: 1, height: 1).fill()
        image.unlockFocus()
        guard let tiff = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:])
        else { return Data() }
        return png
    }
}

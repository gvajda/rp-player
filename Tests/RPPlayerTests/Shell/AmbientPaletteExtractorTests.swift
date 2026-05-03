import AppKit
import XCTest
@testable import RPPlayer

final class AmbientPaletteExtractorTests: XCTestCase {
    private let sut = AmbientPaletteExtractor()

    func testExtractsAverageOfBottomStripFromSolidRedImage() async throws {
        let image = makeSolidColorImage(red: 1.0, green: 0.0, blue: 0.0, size: 100)
        let result = await sut.extractBottomEdgeColor(from: image)
        let color = try XCTUnwrap(result)
        XCTAssertEqual(color.red, 1.0, accuracy: 0.05)
        XCTAssertEqual(color.green, 0.0, accuracy: 0.05)
        XCTAssertEqual(color.blue, 0.0, accuracy: 0.05)
    }

    func testSamplesBottomStripNotWholeImage() async throws {
        // Top half blue, bottom half red. Bottom-edge sample must be red.
        let image = makeTwoBandImage(
            topRed: 0.0, topGreen: 0.0, topBlue: 1.0,
            bottomRed: 1.0, bottomGreen: 0.0, bottomBlue: 0.0,
            size: 100
        )
        let result = await sut.extractBottomEdgeColor(from: image)
        let color = try XCTUnwrap(result)
        XCTAssertEqual(color.red, 1.0, accuracy: 0.05)
        XCTAssertEqual(color.blue, 0.0, accuracy: 0.05)
    }

    func testExtractsMidGrayFromSolidGrayImage() async throws {
        let image = makeSolidColorImage(red: 0.5, green: 0.5, blue: 0.5, size: 60)
        let result = await sut.extractBottomEdgeColor(from: image)
        let color = try XCTUnwrap(result)
        XCTAssertEqual(color.red, 0.5, accuracy: 0.05)
        XCTAssertEqual(color.green, 0.5, accuracy: 0.05)
        XCTAssertEqual(color.blue, 0.5, accuracy: 0.05)
    }

    func testReturnsNilForEmptyImage() async {
        let empty = NSImage(size: .zero)
        let result = await sut.extractBottomEdgeColor(from: empty)
        XCTAssertNil(result)
    }

    private func makeSolidColorImage(red: CGFloat, green: CGFloat, blue: CGFloat, size: Int) -> NSImage {
        let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: size, pixelsHigh: size,
            bitsPerSample: 8, samplesPerPixel: 4,
            hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: size * 4, bitsPerPixel: 32
        )!
        let color = NSColor(srgbRed: red, green: green, blue: blue, alpha: 1.0)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        color.setFill()
        NSRect(x: 0, y: 0, width: size, height: size).fill()
        NSGraphicsContext.restoreGraphicsState()
        let image = NSImage(size: NSSize(width: size, height: size))
        image.addRepresentation(rep)
        return image
    }

    private func makeTwoBandImage(
        topRed: CGFloat, topGreen: CGFloat, topBlue: CGFloat,
        bottomRed: CGFloat, bottomGreen: CGFloat, bottomBlue: CGFloat,
        size: Int
    ) -> NSImage {
        let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: size, pixelsHigh: size,
            bitsPerSample: 8, samplesPerPixel: 4,
            hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: size * 4, bitsPerPixel: 32
        )!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        // NSGraphicsContext origin is bottom-left. "Top" half draws at upper y range.
        let half = CGFloat(size) / 2.0
        NSColor(srgbRed: topRed, green: topGreen, blue: topBlue, alpha: 1.0).setFill()
        NSRect(x: 0, y: half, width: CGFloat(size), height: half).fill()
        NSColor(srgbRed: bottomRed, green: bottomGreen, blue: bottomBlue, alpha: 1.0).setFill()
        NSRect(x: 0, y: 0, width: CGFloat(size), height: half).fill()
        NSGraphicsContext.restoreGraphicsState()
        let image = NSImage(size: NSSize(width: size, height: size))
        image.addRepresentation(rep)
        return image
    }
}

import AppKit
import SwiftUI

protocol AmbientPaletteExtracting: Sendable {
    func extractBottomEdgeColor(from image: NSImage) async -> ExtractedColor?
}

struct ExtractedColor: Equatable, Sendable {
    let red: Double
    let green: Double
    let blue: Double

    var swiftUIColor: Color { Color(red: red, green: green, blue: blue) }
}

actor AmbientPaletteExtractor: AmbientPaletteExtracting {
    func extractBottomEdgeColor(from image: NSImage) async -> ExtractedColor? {
        guard let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            return nil
        }
        let height = cgImage.height
        let width = cgImage.width
        guard width > 0, height > 0 else { return nil }
        let stripHeight = max(1, height / 20)
        let stripRect = CGRect(x: 0, y: height - stripHeight, width: width, height: stripHeight)
        guard let strip = cgImage.cropping(to: stripRect) else { return nil }

        var bitmap = [UInt8](repeating: 0, count: 4)
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = CGImageAlphaInfo.noneSkipLast.rawValue
        guard let ctx = CGContext(
            data: &bitmap,
            width: 1, height: 1,
            bitsPerComponent: 8,
            bytesPerRow: 4,
            space: colorSpace,
            bitmapInfo: bitmapInfo
        ) else { return nil }
        ctx.interpolationQuality = .high
        ctx.draw(strip, in: CGRect(x: 0, y: 0, width: 1, height: 1))

        return ExtractedColor(
            red: Double(bitmap[0]) / 255.0,
            green: Double(bitmap[1]) / 255.0,
            blue: Double(bitmap[2]) / 255.0
        )
    }
}

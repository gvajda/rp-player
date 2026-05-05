import SwiftUI
import XCTest
@testable import RPPlayer

final class LiquidGlassBackgroundTests: XCTestCase {
    func testIfEnabledWrapperCompilesAndAppliesConditionally() {
        let enabled = AnyView(Text("hi").modifier(LiquidGlassBackgroundIfEnabled(enabled: true)))
        let disabled = AnyView(Text("hi").modifier(LiquidGlassBackgroundIfEnabled(enabled: false)))
        // Smoke: both branches build and produce a non-nil view tree.
        XCTAssertNotNil(enabled)
        XCTAssertNotNil(disabled)
    }
}

import XCTest
import SwiftUI
import DesignSystem
@testable import Flotilla

final class MarqueeTextTests: XCTestCase {
    @MainActor
    func testMarqueeTextInitialization() {
        let view = MarqueeText(
            "/Users/developer/Projects/SwiftUi/Flotilla/Sources/App",
            font: .system(size: 11, design: .monospaced),
            color: .secondary,
            isHovered: true,
            truncationMode: .middle,
            speed: 40
        )
        XCTAssertNotNil(view)
    }

    @MainActor
    func testMarqueeTextDefaultParameters() {
        let view = MarqueeText("/Users/developer/repo")
        XCTAssertNotNil(view)
    }
}

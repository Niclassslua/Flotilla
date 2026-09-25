import XCTest
import SwiftUI
import DesignSystem

final class FlotillaAccentTests: XCTestCase {
    func testOriginalIDResolvesOriginalColor() {
        let originalPlatform = FlotillaAccent.platformColor(for: "original")
        let fallbackPlatform = FlotillaAccent.platformColor(for: "unknown-id")
        XCTAssertEqual(originalPlatform, fallbackPlatform)
    }

    func testResetToDefaultIDRestoresOriginalAccent() {
        FlotillaAccent.currentID = "blue"
        XCTAssertEqual(FlotillaAccent.currentID, "blue")

        FlotillaAccent.currentID = FlotillaAccent.defaultID
        XCTAssertEqual(FlotillaAccent.currentID, "original")
        XCTAssertEqual(FlotillaAccent.currentColor, FlotillaColors.originalAccent)
    }

    func testStorageValueHexRoundTrip() {
        let hex = "#336699"
        let color = FlotillaAccent.color(for: hex)
        let stored = FlotillaAccent.storageValue(for: color)
        XCTAssertEqual(stored?.uppercased(), hex.uppercased())
    }
}

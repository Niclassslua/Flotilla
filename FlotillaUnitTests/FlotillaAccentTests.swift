import XCTest
import SwiftUI
import DesignSystem

final class FlotillaAccentTests: XCTestCase {
    func testOptionLookup() {
        XCTAssertEqual(FlotillaAccent.options.count, 6)
        let ids = FlotillaAccent.options.map(\.id)
        XCTAssertEqual(ids, ["blue", "purple", "pink", "red", "orange", "green"])
    }

    func testPlatformColorHexParsing() {
        let redHex = "#FF0000"
        let color = FlotillaAccent.platformColor(for: redHex)
        XCTAssertNotNil(color)

        let invalid = FlotillaAccent.platformColor(for: "not-a-color")
        XCTAssertNotNil(invalid)
    }

    func testCurrentIDUpdatesCurrentColor() {
        FlotillaAccent.currentID = "blue"
        XCTAssertEqual(FlotillaAccent.currentID, "blue")

        FlotillaAccent.currentID = "purple"
        XCTAssertEqual(FlotillaAccent.currentID, "purple")

        FlotillaAccent.currentID = "orange"
        XCTAssertEqual(FlotillaAccent.currentID, "orange")
    }

    func testDefaultIDIsOriginal() {
        XCTAssertEqual(FlotillaAccent.defaultID, "original")
        XCTAssertEqual(FlotillaAccent.originalID, "original")
    }

    func testOriginalColorMatchesBrandValues() {
        let darkColor = FlotillaAccent.originalPlatformColor(isDark: true)
        #if os(macOS)
        let srgbDark = darkColor.usingColorSpace(.sRGB)
        XCTAssertEqual(srgbDark?.redComponent ?? 0, 0.96, accuracy: 0.01)
        XCTAssertEqual(srgbDark?.greenComponent ?? 0, 0.36, accuracy: 0.01)
        XCTAssertEqual(srgbDark?.blueComponent ?? 0, 0.16, accuracy: 0.01)
        #else
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        darkColor.getRed(&r, green: &g, blue: &b, alpha: &a)
        XCTAssertEqual(r, 0.96, accuracy: 0.01)
        XCTAssertEqual(g, 0.36, accuracy: 0.01)
        XCTAssertEqual(b, 0.16, accuracy: 0.01)
        #endif
    }

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

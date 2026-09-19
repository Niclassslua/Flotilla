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

    func testStorageValueHexRoundTrip() {
        let hex = "#336699"
        let color = FlotillaAccent.color(for: hex)
        let stored = FlotillaAccent.storageValue(for: color)
        XCTAssertEqual(stored?.uppercased(), hex.uppercased())
    }
}

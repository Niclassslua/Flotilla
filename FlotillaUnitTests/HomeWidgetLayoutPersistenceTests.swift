import XCTest
import SettingsKit
@testable import Flotilla

final class HomeWidgetLayoutPersistenceTests: XCTestCase {
    private func roundTrip(_ prefs: WorkspacePreferences) throws -> WorkspacePreferences {
        let data = try JSONEncoder().encode(prefs)
        return try JSONDecoder().decode(WorkspacePreferences.self, from: data)
    }

    func testNilHomeWidgetsRoundTripsAsNil() throws {
        let prefs = WorkspacePreferences(homeWidgets: nil)
        let decoded = try roundTrip(prefs)
        XCTAssertNil(decoded.homeWidgets)
    }

    func testHomeWidgetsRoundTripPreservesOrderAndConfig() throws {
        let entries = [
            HomeWidgetEntry(kind: "hotFiles", size: "medium", config: HomeWidgetConfig(projectID: "abc", timeWindowDays: 30)),
            HomeWidgetEntry(kind: "streak", size: "small"),
        ]
        let prefs = WorkspacePreferences(homeWidgets: entries)
        let decoded = try roundTrip(prefs)
        XCTAssertEqual(decoded.homeWidgets?.map(\.kind), ["hotFiles", "streak"])
        XCTAssertEqual(decoded.homeWidgets?.first?.config.projectID, "abc")
        XCTAssertEqual(decoded.homeWidgets?.first?.config.timeWindowDays, 30)
    }

    func testDecodingOlderSettingsFileWithoutHomeWidgetsFieldsDefaultsGracefully() throws {
        // Simulates a settings file saved before this feature existed.
        let legacyJSON = """
        {
            "viewMode": "single",
            "detailPanel": "terminal",
            "gridColumnCount": 3,
            "gridRowCount": 2,
            "gridSelectedSessionIDs": [],
            "gridDimEnabled": false,
            "gridDimIntensity": 0.4,
            "sidebarRailLabels": false,
            "sessionGroup": "all"
        }
        """
        let decoded = try JSONDecoder().decode(WorkspacePreferences.self, from: Data(legacyJSON.utf8))
        XCTAssertNil(decoded.homeWidgets)
        XCTAssertEqual(decoded.homeWidgetsVersion, HomeWidgetEntry.currentVersion)
        XCTAssertFalse(decoded.homeCustomizeHintShown)
    }

    func testUnrecognizedWidgetKindIsDroppedWhenResolved() {
        let entry = HomeWidgetEntry(kind: "someFutureWidget", size: "medium")
        XCTAssertNil(entry.resolvedKind)
    }

    func testUnrecognizedSizeIsDroppedWhenResolved() {
        let entry = HomeWidgetEntry(kind: "streak", size: "xxl")
        XCTAssertNotNil(entry.resolvedKind)
        XCTAssertNil(entry.resolvedSize)
    }

    func testEveryWidgetKindResolvesADefaultSizeThatItSupports() {
        for kind in HomeWidgetKind.allCases {
            XCTAssertTrue(kind.supportedSizes.contains(kind.defaultSize), "\(kind) default size not in its own supportedSizes")
        }
    }

    func testDefaultLayoutEntriesAllResolve() {
        for entry in HomeWidgetKind.defaultLayout {
            XCTAssertNotNil(entry.resolvedKind, "unresolved kind: \(entry.kind)")
            XCTAssertNotNil(entry.resolvedSize, "unresolved size: \(entry.size)")
        }
    }

    func testConfigIsDefaultWhenAllFieldsAreNil() {
        XCTAssertTrue(HomeWidgetConfig().isDefault)
        XCTAssertFalse(HomeWidgetConfig(projectID: "x").isDefault)
        XCTAssertFalse(HomeWidgetConfig(timeWindowDays: 7).isDefault)
        XCTAssertFalse(HomeWidgetConfig(agent: "claudeCode").isDefault)
    }
}

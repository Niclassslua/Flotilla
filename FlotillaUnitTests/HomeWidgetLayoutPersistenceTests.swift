import XCTest
import SettingsKit
@testable import Flotilla

final class HomeWidgetLayoutPersistenceTests: XCTestCase {
    private func roundTrip(_ prefs: WorkspacePreferences) throws -> WorkspacePreferences {
        let data = try JSONEncoder().encode(prefs)
        return try JSONDecoder().decode(WorkspacePreferences.self, from: data)
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
        // Simulates a settings file saved before this feature existed, including
        // legacy keys that WorkspacePreferences no longer stores.
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
        XCTAssertEqual(decoded.sessionGroup, "all")
        XCTAssertEqual(decoded.gridColumnCount, 3)
    }

    func testResolutionDropsUnknownKindOrSizeAndDefaultsAllResolve() {
        XCTAssertNil(HomeWidgetEntry(kind: "someFutureWidget", size: "medium").resolvedKind)
        let unknownSize = HomeWidgetEntry(kind: "streak", size: "xxl")
        XCTAssertNotNil(unknownSize.resolvedKind)
        XCTAssertNil(unknownSize.resolvedSize)
        for entry in HomeWidgetKind.defaultLayout {
            XCTAssertNotNil(entry.resolvedKind, "unresolved kind: \(entry.kind)")
            XCTAssertNotNil(entry.resolvedSize, "unresolved size: \(entry.size)")
        }
    }
}

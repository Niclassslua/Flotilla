import XCTest
@testable import Flotilla

/// Sidebar project sections default to expanded and persist their collapsed
/// set across app launches.
final class SidebarProjectCollapseStateTests: XCTestCase {
    private var defaults: UserDefaults!
    private var suiteName: String!

    override func setUp() {
        super.setUp()
        suiteName = "SidebarProjectCollapseStateTests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        super.tearDown()
    }

    func testStartsExpandedWithNothingSaved() {
        XCTAssertEqual(SidebarProjectCollapseState.load(defaults: defaults), [])
    }

    func testSavedCollapsedSetSurvivesAFreshLoad() {
        let ids: Set<UUID> = [UUID(), UUID()]
        SidebarProjectCollapseState.save(ids, defaults: defaults)
        XCTAssertEqual(SidebarProjectCollapseState.load(defaults: defaults), ids)
    }
}

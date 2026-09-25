import XCTest
import CompanionKit
@testable import FlotillaCompanion

/// Fleet project collapse state persists per Mac, defaults to expanded.
@MainActor
final class CollapsedProjectsTests: XCTestCase {
    private var defaults: UserDefaults!
    private var suiteName: String!

    override func setUp() {
        super.setUp()
        suiteName = "CollapsedProjectsTests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        super.tearDown()
    }

    private func makeStore() -> CompanionStore {
        CompanionStore(data: MockCompanionDataSource(), defaults: defaults)
    }
    func testCollapsedProjectsPersistAcrossStoreInstancesPerMac() {
        let store = makeStore()
        store.setCollapsedProjects(["Flotilla"], on: MockFixtures.MacID.studio)

        let relaunched = makeStore()
        XCTAssertEqual(relaunched.collapsedProjects(on: MockFixtures.MacID.studio), ["Flotilla"])
        XCTAssertEqual(relaunched.collapsedProjects(on: MockFixtures.MacID.macBook), [], "collapse state is per Mac")
    }
}

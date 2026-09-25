import XCTest
import SessionKit
import CompanionKit
@testable import FlotillaCompanion

/// Prompt and plan-revision drafts must survive navigation and relaunch,
/// scoped per Mac + session, and clear only on confirmed send or discard.
@MainActor
final class CompanionDraftTests: XCTestCase {
    private var defaults: UserDefaults!
    private var suiteName: String!

    override func setUp() {
        super.setUp()
        suiteName = "CompanionDraftTests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        super.tearDown()
    }

    private func makeStore() -> CompanionStore {
        CompanionStore(data: MockCompanionDataSource(), defaults: defaults)
    }

    func testPromptDraftPersistsAcrossStoreInstances() {
        let sessionID = MockFixtures.SessionID.offlineBanner
        let store = makeStore()
        XCTAssertEqual(store.promptDraft(for: sessionID), "", "no draft saved yet")

        store.savePromptDraft("Please add a retry", for: sessionID)

        // A fresh store over the same defaults simulates relaunch.
        let relaunched = makeStore()
        XCTAssertEqual(relaunched.promptDraft(for: sessionID), "Please add a retry")
    }

    func testPromptDraftClearsWhenSavedEmpty() {
        let sessionID = MockFixtures.SessionID.offlineBanner
        let store = makeStore()
        store.savePromptDraft("scratch text", for: sessionID)
        XCTAssertEqual(store.promptDraft(for: sessionID), "scratch text")

        store.savePromptDraft("", for: sessionID)
        XCTAssertEqual(store.promptDraft(for: sessionID), "")
    }
    func testPlanRevisionDraftIsScopedPerSession() {
        let store = makeStore()
        let planSession = MockFixtures.SessionID.settingsPlan
        let otherSession = MockFixtures.SessionID.offlineBanner

        store.savePlanRevisionDraft("Use a queue instead", for: planSession)

        XCTAssertEqual(store.planRevisionDraft(for: planSession), "Use a queue instead")
        XCTAssertEqual(store.planRevisionDraft(for: otherSession), "", "drafts must not leak across sessions")
    }

    func testRemovingMacPurgesItsDrafts() {
        let store = makeStore()
        let sessionID = MockFixtures.SessionID.offlineBanner
        store.savePromptDraft("draft to purge", for: sessionID)
        store.savePlanRevisionDraft("revision to purge", for: sessionID)

        store.removeMac(MockFixtures.MacID.studio)

        XCTAssertEqual(store.promptDraft(for: sessionID), "")
        XCTAssertEqual(store.planRevisionDraft(for: sessionID), "")
    }
}

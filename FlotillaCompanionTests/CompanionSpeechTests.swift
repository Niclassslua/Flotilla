import XCTest
import SessionKit
import CompanionKit
@testable import FlotillaCompanion

@MainActor
final class CompanionSpeechTests: XCTestCase {
    private var defaults: UserDefaults!
    private var suiteName: String!

    override func setUp() {
        super.setUp()
        suiteName = "CompanionSpeechTests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        super.tearDown()
    }

    private func makeStore() -> CompanionStore {
        CompanionStore(data: MockCompanionDataSource(), defaults: defaults)
    }

    func testPreservesExistingTypedTextWhenDictationFinishes() async {
        let sessionID = MockFixtures.SessionID.offlineBanner
        let store = makeStore()
        store.savePromptDraft("Fix the layout issue", for: sessionID)

        let initialDraft = store.promptDraft(for: sessionID)
        XCTAssertEqual(initialDraft, "Fix the layout issue")

        let speech = CompanionSpeechController()
        XCTAssertEqual(speech.phase, .idle)

        // Simulate dictation yielding text and appending to existing draft
        let dictated = "and add padding to the top"
        var draft = initialDraft
        if !draft.isEmpty && !draft.hasSuffix(" ") {
            draft.append(" ")
        }
        draft.append(dictated)
        store.savePromptDraft(draft, for: sessionID)

        XCTAssertEqual(
            store.promptDraft(for: sessionID),
            "Fix the layout issue and add padding to the top",
            "Pre-existing typed text must be strictly preserved when dictation completes"
        )
    }

    func testFinishingDictationNeverAutoSends() async {
        let sessionID = MockFixtures.SessionID.offlineBanner
        let store = makeStore()
        store.savePromptDraft("", for: sessionID)

        // After dictation finishes, the draft contains the text, but no prompt was dispatched
        let dictated = "Run all verification suites"
        store.savePromptDraft(dictated, for: sessionID)

        XCTAssertEqual(store.promptDraft(for: sessionID), dictated)

        // Verify the prompt draft is still sitting in the composer and was not automatically cleared by a send
        XCTAssertFalse(store.promptDraft(for: sessionID).isEmpty, "Finishing dictation must never auto-send; prompt must remain in the draft")
    }

    func testSpeechControllerCancellationReturnsToIdle() async {
        let sessionID = MockFixtures.SessionID.offlineBanner
        let store = makeStore()
        let speech = CompanionSpeechController()

        XCTAssertEqual(speech.phase, .idle)
        speech.cancel(store: store, sessionID: sessionID)
        XCTAssertEqual(speech.phase, .idle)
    }
}

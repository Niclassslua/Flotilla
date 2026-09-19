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

    func testSpeechDisabledWhenNotAvailable() async {
        let sessionID = MockFixtures.SessionID.offlineBanner
        let store = makeStore()
        let speech = CompanionSpeechController()

        XCTAssertFalse(speech.isAvailable, "Speech must default to unavailable until verified")
        await speech.begin(store: store, sessionID: sessionID)
        XCTAssertEqual(speech.phase, .idle, "Speech begin must be a no-op when isAvailable is false")

        await speech.checkAvailability(store: store, sessionID: sessionID)
        XCTAssertTrue(speech.isAvailable, "Mock source reports speech ready, so isAvailable must become true")
    }

    func testStoreSpeechAvailabilityHelpers() {
        let store = makeStore()
        let sessionID = MockFixtures.SessionID.offlineBanner
        XCTAssertTrue(store.isSpeechAvailable(for: sessionID))
        XCTAssertTrue(store.isAnyMacSpeechAvailable)
    }

    // MARK: - Audio level meter

    private func meterLevels(_ chunks: [[Float]]) -> [CompanionAudioLevelUpdate] {
        var meter = CompanionAudioLevelMeter()
        return chunks.map { chunk in chunk.withUnsafeBufferPointer { meter.process($0) } }
    }

    private func tone(amplitude: Float, seconds: Double) -> [Float] {
        let count = Int(CompanionAudioLevelMeter.sampleRate * seconds)
        return (0..<count).map { amplitude * sin(Float($0) * 0.3) }
    }

    func testLoudSoundDoesNotFlattenFollowingSpeech() {
        let speech = tone(amplitude: 0.05, seconds: 0.2)
        let before = meterLevels([speech])[0].samples.last!.level
        let updates = meterLevels([speech, tone(amplitude: 0.9, seconds: 0.2), speech])
        let after = updates[2].samples.last!.level

        XCTAssertEqual(after, before, accuracy: 0.001,
                       "Each slot is a snapshot: a loud slot must not rescale later ones")
        XCTAssertGreaterThan(updates[1].samples.last!.level, after)
    }

    func testSilenceDropsImmediatelyAfterLoudSound() {
        let updates = meterLevels([tone(amplitude: 0.9, seconds: 0.2),
                                   [Float](repeating: 0, count: 3_200)])
        XCTAssertEqual(updates[1].samples.last!.level, 0)
    }

    func testSlotsAreContiguousAcrossBufferBoundaries() {
        // 1_000-sample buffers straddle the 3_200-sample slot boundaries.
        let updates = meterLevels(Array(repeating: tone(amplitude: 0.1, seconds: 0.0625), count: 10))
        let ids = updates.flatMap { $0.samples.map(\.id) }
        XCTAssertEqual(Array(Set(ids)).sorted(), [0, 1, 2, 3])
        XCTAssertEqual(updates.last!.audioTime, 0.625, accuracy: 0.0001)
    }

    func testLevelUsesDecibelScale() {
        XCTAssertEqual(CompanionAudioLevelMeter.level(rms: 0), 0)
        XCTAssertEqual(CompanionAudioLevelMeter.level(rms: pow(10, -50.0 / 20)), 0, accuracy: 0.001)
        XCTAssertEqual(CompanionAudioLevelMeter.level(rms: pow(10, -30.0 / 20)), 0.5, accuracy: 0.001)
        XCTAssertEqual(CompanionAudioLevelMeter.level(rms: 1), 1)
    }
}

import XCTest
import SessionKit
@testable import TranscriptKit

/// Antigravity is a handoff source and never a destination. These tests cover
/// the reading, and — just as importantly — that the registry keeps it out of
/// the destination list without anyone writing that rule by hand.
final class AntigravityTranscriptCodecTests: XCTestCase {
    private var brain: URL!
    private var codec: AntigravityTranscriptCodec!
    private let conversationID = "c8edbc25-7a71-4173-9f1b-a97d14aef556"

    override func setUpWithError() throws {
        try super.setUpWithError()
        brain = FileManager.default.temporaryDirectory
            .appendingPathComponent("AntigravityTests-\(UUID().uuidString)", isDirectory: true)
        codec = AntigravityTranscriptCodec(brainDirectory: brain)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: brain)
        try super.tearDownWithError()
    }

    @discardableResult
    private func writeTranscript(_ lines: [String]) throws -> URL {
        let directory = brain
            .appendingPathComponent(conversationID, isDirectory: true)
            .appendingPathComponent(".system_generated/logs", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = directory.appendingPathComponent("transcript.jsonl")
        try lines.joined(separator: "\n").write(to: file, atomically: true, encoding: .utf8)
        return file
    }

    func testLocatesTheLogInsideTheConversationDirectory() throws {
        let written = try writeTranscript([
            #"{"step_index":0,"source":"USER_EXPLICIT","type":"USER_INPUT","status":"DONE","created_at":"2026-08-22T02:24:36Z","content":"hello"}"#
        ])
        let found = try codec.transcriptURL(sessionID: conversationID, workingDirectory: URL(fileURLWithPath: "/tmp"))
        XCTAssertEqual(found?.standardizedFileURL, written.standardizedFileURL)
    }

    func testMapsEachSpeakerToItsCanonicalEntry() throws {
        let url = try writeTranscript([
            #"{"step_index":0,"source":"USER_EXPLICIT","type":"USER_INPUT","status":"DONE","created_at":"2026-08-22T02:24:36Z","content":"<USER_REQUEST>\nfix the tests\n</USER_REQUEST>"}"#,
            #"{"step_index":1,"source":"SYSTEM","type":"CHECKPOINT","status":"DONE","created_at":"2026-08-22T02:24:37Z","content":"{{ CHECKPOINT 0 }}"}"#,
            #"{"step_index":2,"source":"MODEL","type":"PLANNER_RESPONSE","status":"DONE","created_at":"2026-08-22T02:24:38Z","content":"on it"}"#
        ])

        let entries = try codec.readNative(at: url)

        XCTAssertEqual(entries.count, 3)
        guard case let .userMessage(text, _) = entries[0] else {
            return XCTFail("expected a user message, got \(entries[0])")
        }
        XCTAssertEqual(text, "fix the tests", "Antigravity's own framing is stripped")

        guard case .systemNote = entries[1] else {
            return XCTFail("expected a system note, got \(entries[1])")
        }
        guard case let .assistantMessage(reply, _) = entries[2] else {
            return XCTFail("expected an assistant message, got \(entries[2])")
        }
        XCTAssertEqual(reply, "on it")
    }

    func testEmptyAndUnrecognisedStepsAreSkipped() throws {
        let url = try writeTranscript([
            #"{"step_index":0,"source":"MODEL","type":"PLANNER_RESPONSE","status":"DONE","created_at":"2026-08-22T02:24:38Z","content":""}"#,
            #"{"step_index":1,"source":"SOMETHING_NEW","type":"?","status":"DONE","created_at":"2026-08-22T02:24:39Z","content":"ignore me"}"#,
            "not json",
            #"{"step_index":2,"source":"MODEL","type":"GENERIC","status":"DONE","created_at":"2026-08-22T02:24:40Z","content":"kept"}"#
        ])

        let entries = try codec.readNative(at: url)

        XCTAssertEqual(entries.count, 1)
        guard case let .assistantMessage(text, _) = entries[0] else {
            return XCTFail("expected an assistant message, got \(entries[0])")
        }
        XCTAssertEqual(text, "kept")
    }

    /// The log records no identity, so the codec says so instead of guessing —
    /// which lets the handoff skip ownership verification rather than fail it.
    func testItReportsThatItCannotVerifyIdentity() throws {
        let url = try writeTranscript([
            #"{"step_index":0,"source":"MODEL","type":"GENERIC","status":"DONE","created_at":"2026-08-22T02:24:38Z","content":"hi"}"#
        ])
        XCTAssertNil(try codec.embeddedSessionID(at: url))
    }

    func testTheShippingRegistryOffersAntigravityAsASourceButNeverADestination() {
        let registry = TranscriptCodecRegistry.default

        XCTAssertTrue(registry.readableAgents.contains(.antigravity))
        XCTAssertFalse(registry.writableAgents.contains(.antigravity))
        XCTAssertEqual(
            Set(registry.handoffTargets(from: .antigravity)),
            [.claudeCode, .codexCLI],
            "a session can escape Antigravity"
        )
        XCTAssertFalse(
            registry.handoffTargets(from: .claudeCode).contains(.antigravity),
            "but never arrive at it"
        )
    }
}

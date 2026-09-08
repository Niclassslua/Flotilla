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

    // MARK: - Discovery

    /// Antigravity writes its `conversation_summaries.db` row only once it has
    /// titled a conversation, and writes no workspace into the log at all — so
    /// a live session is invisible to title/cwd matching. Discovery keys off the
    /// launch time instead, which is what makes a fresh session handoff-able.
    func testDiscoversAConversationStartedAfterLaunch() throws {
        let launchedAt = Date()
        try writeTranscript([
            #"{"step_index":0,"source":"USER_EXPLICIT","type":"USER_INPUT","status":"DONE","created_at":"2026-08-22T02:24:36Z","content":"do the thing"}"#
        ])

        let found = try codec.discoverSession(
            workingDirectory: URL(fileURLWithPath: "/tmp/anything"),
            since: launchedAt.addingTimeInterval(-30)
        )

        XCTAssertEqual(found?.sessionID, conversationID, "no title and no workspace required")
        XCTAssertNotNil(found?.url)
    }

    /// The guard that keeps this from resolving to somebody else's session.
    func testIgnoresConversationsCreatedBeforeTheLaunch() throws {
        try writeTranscript([
            #"{"step_index":0,"source":"USER_EXPLICIT","type":"USER_INPUT","status":"DONE","created_at":"2026-08-22T02:24:36Z","content":"an older conversation"}"#
        ])

        XCTAssertNil(try codec.discoverSession(
            workingDirectory: URL(fileURLWithPath: "/tmp/anything"),
            since: Date().addingTimeInterval(60)
        ), "a conversation that predates the launch is not ours")
    }

    /// The association that matters when several sessions have run: ours is the
    /// first conversation created after we launched, not the most recent one.
    /// A conversation created weeks ago but touched today would win on
    /// modification time and is a different session entirely.
    func testPicksTheEarliestConversationStartedAfterTheLaunch() throws {
        let launchedAt = Date()

        let ours = try writeTranscript(
            [#"{"step_index":0,"source":"USER_EXPLICIT","type":"USER_INPUT","status":"DONE","created_at":"2026-08-22T02:24:36Z","content":"ours"}"#]
        )
        // A conversation a later session started.
        let laterID = "ffffffff-1111-2222-3333-444444444444"
        let laterDirectory = brain
            .appendingPathComponent(laterID, isDirectory: true)
            .appendingPathComponent(".system_generated/logs", isDirectory: true)
        try FileManager.default.createDirectory(at: laterDirectory, withIntermediateDirectories: true)
        try #"{"step_index":0,"source":"USER_EXPLICIT","type":"USER_INPUT","status":"DONE","created_at":"2026-08-22T02:24:36Z","content":"theirs"}"#
            .write(to: laterDirectory.appendingPathComponent("transcript.jsonl"), atomically: true, encoding: .utf8)

        // Make ours unambiguously the earlier of the two.
        try FileManager.default.setAttributes(
            [.creationDate: launchedAt.addingTimeInterval(5)],
            ofItemAtPath: brain.appendingPathComponent(conversationID).path
        )
        try FileManager.default.setAttributes(
            [.creationDate: launchedAt.addingTimeInterval(600)],
            ofItemAtPath: brain.appendingPathComponent(laterID).path
        )

        let found = try codec.discoverSession(
            workingDirectory: URL(fileURLWithPath: "/tmp/anything"),
            since: launchedAt.addingTimeInterval(-30)
        )

        XCTAssertEqual(found?.sessionID, conversationID)
        XCTAssertEqual(found?.url.standardizedFileURL, ours.standardizedFileURL)
    }

    /// A directory the agent created but never spoke in is not worth moving.
    func testIgnoresAConversationWithNoContent() throws {
        try writeTranscript([
            #"{"step_index":0,"source":"SYSTEM","type":"CHECKPOINT","status":"DONE","created_at":"2026-08-22T02:24:36Z","content":"{{ CHECKPOINT 0 }}"}"#
        ])

        XCTAssertNil(try codec.discoverSession(
            workingDirectory: URL(fileURLWithPath: "/tmp/anything"),
            since: Date().addingTimeInterval(-30)
        ))
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

import XCTest
import SessionKit
import SQLite3
@testable import TranscriptKit

/// Antigravity is now both a handoff source and a target — see `FORMAT.md`
/// next to `AntigravityTranscriptCodec` for the reverse-engineered wire
/// format these tests exercise. Fixture databases here are hand-built with
/// the same `AntigravityWireFormat` primitives the codec itself uses, kept
/// deliberately independent of `writeNative` so the read side is verified
/// against fixtures it did not produce.
final class AntigravityTranscriptCodecTests: XCTestCase {
    private var root: URL!
    private var brain: URL!
    private var codec: AntigravityTranscriptCodec!
    private let conversationID = "c8edbc25-7a71-4173-9f1b-a97d14aef556"

    override func setUpWithError() throws {
        try super.setUpWithError()
        // `conversations/` is a *sibling* of `brain/`, both under
        // `antigravity-cli/` (see `AntigravityTranscriptCodec.conversationsDirectory`)
        // — the fixture has to mirror that shape, or `conversations/` resolves
        // outside this test's isolated root and collides with every other
        // test run using the real `brainDirectory` layout in parallel.
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("AntigravityTests-\(UUID().uuidString)", isDirectory: true)
        brain = root.appendingPathComponent("antigravity-cli/brain", isDirectory: true)
        codec = AntigravityTranscriptCodec(brainDirectory: brain)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
        try super.tearDownWithError()
    }

    // MARK: - Fixture helpers

    private var conversationsDirectory: URL {
        brain.deletingLastPathComponent().appendingPathComponent("conversations", isDirectory: true)
    }

    /// Builds a conversation database directly with `AntigravityWireFormat`,
    /// bypassing `writeNative` entirely, so read tests are not just checking
    /// that the codec agrees with itself.
    @discardableResult
    private func writeDatabase(id: String = "", steps: [(type: Int, payload: Data)]) throws -> URL {
        let conversationID = id.isEmpty ? self.conversationID : id
        try FileManager.default.createDirectory(at: conversationsDirectory, withIntermediateDirectories: true)
        let file = conversationsDirectory.appendingPathComponent("\(conversationID).db")
        try? FileManager.default.removeItem(at: file)

        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open_v2(file.path, &db, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE, nil), SQLITE_OK)
        defer { sqlite3_close(db) }

        XCTAssertEqual(sqlite3_exec(db, """
        CREATE TABLE `steps` (`idx` integer,`step_type` integer,`step_payload` blob, PRIMARY KEY (`idx`))
        """, nil, nil, nil), SQLITE_OK)

        for (index, step) in steps.enumerated() {
            var statement: OpaquePointer?
            XCTAssertEqual(sqlite3_prepare_v2(db, "INSERT INTO steps (idx, step_type, step_payload) VALUES (?, ?, ?)", -1, &statement, nil), SQLITE_OK)
            sqlite3_bind_int(statement, 1, Int32(index))
            sqlite3_bind_int(statement, 2, Int32(step.type))
            let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
            step.payload.withUnsafeBytes { raw in
                _ = sqlite3_bind_blob(statement, 3, raw.baseAddress, Int32(step.payload.count), transient)
            }
            XCTAssertEqual(sqlite3_step(statement), SQLITE_DONE)
            sqlite3_finalize(statement)
        }

        // The conversation's brain directory need only exist for discovery
        // to find it — it doesn't need real log content, since reading now
        // goes through the database.
        try FileManager.default.createDirectory(
            at: brain.appendingPathComponent(conversationID, isDirectory: true),
            withIntermediateDirectories: true
        )
        return file
    }

    private static func timestampField(_ number: Int, seconds: UInt64) -> AntigravityWireFormat.Field {
        AntigravityWireFormat.messageField(number, [AntigravityWireFormat.varintField(1, seconds)])
    }

    private static func userStepPayload(text: String, seconds: UInt64 = 1_789_000_000) -> Data {
        let envelope: [AntigravityWireFormat.Field] = [
            timestampField(1, seconds: seconds),
            AntigravityWireFormat.varintField(3, 4) // role: user
        ]
        return AntigravityWireFormat.serialize([
            AntigravityWireFormat.varintField(1, 14),
            AntigravityWireFormat.messageField(5, envelope),
            AntigravityWireFormat.messageField(19, [
                AntigravityWireFormat.stringField(2, text)
            ])
        ])
    }

    private static func assistantStepPayload(text: String, seconds: UInt64 = 1_789_000_001) -> Data {
        let envelope: [AntigravityWireFormat.Field] = [
            timestampField(1, seconds: seconds),
            AntigravityWireFormat.varintField(3, 2) // role: assistant
        ]
        return AntigravityWireFormat.serialize([
            AntigravityWireFormat.varintField(1, 15),
            AntigravityWireFormat.messageField(5, envelope),
            AntigravityWireFormat.messageField(20, [
                AntigravityWireFormat.stringField(1, text)
            ])
        ])
    }

    /// Simulates a step produced by a thinking-capable model: `reasoning` in
    /// field 20.1 (the chain-of-thought) and `response` in field 20.8 (the
    /// clean visible reply). In non-thinking sessions both fields are identical.
    private static func thinkingAssistantStepPayload(
        reasoning: String,
        response: String,
        seconds: UInt64 = 1_789_000_001
    ) -> Data {
        let envelope: [AntigravityWireFormat.Field] = [
            timestampField(1, seconds: seconds),
            AntigravityWireFormat.varintField(3, 2) // role: assistant
        ]
        return AntigravityWireFormat.serialize([
            AntigravityWireFormat.varintField(1, 15),
            AntigravityWireFormat.messageField(5, envelope),
            AntigravityWireFormat.messageField(20, [
                AntigravityWireFormat.stringField(1, reasoning), // 20.1: reasoning trace
                AntigravityWireFormat.stringField(8, response)   // 20.8: visible response
            ])
        ])
    }

    private static func systemStepPayload(text: String, seconds: UInt64 = 1_789_000_002) -> Data {
        let envelope: [AntigravityWireFormat.Field] = [
            timestampField(1, seconds: seconds),
            AntigravityWireFormat.varintField(3, 5)
        ]
        return AntigravityWireFormat.serialize([
            AntigravityWireFormat.varintField(1, 101),
            AntigravityWireFormat.messageField(5, envelope),
            AntigravityWireFormat.messageField(114, [
                AntigravityWireFormat.stringField(1, text)
            ])
        ])
    }

    private static func toolCallStepPayload(callID: String, tool: String, argumentsJSON: String, seconds: UInt64 = 1_789_000_003) -> Data {
        let call = AntigravityWireFormat.messageField(4, [
            AntigravityWireFormat.stringField(1, callID),
            AntigravityWireFormat.stringField(2, tool),
            AntigravityWireFormat.stringField(3, argumentsJSON)
        ])
        let envelope: [AntigravityWireFormat.Field] = [
            timestampField(1, seconds: seconds),
            AntigravityWireFormat.varintField(3, 2),
            call
        ]
        return AntigravityWireFormat.serialize([
            AntigravityWireFormat.varintField(1, 132),
            AntigravityWireFormat.messageField(5, envelope)
        ])
    }

    // MARK: - Reading

    func testLocatesTheConversationDatabase() throws {
        let written = try writeDatabase(steps: [(14, Self.userStepPayload(text: "hello"))])
        let found = try codec.transcriptURL(sessionID: conversationID, workingDirectory: URL(fileURLWithPath: "/tmp"))
        XCTAssertEqual(found?.standardizedFileURL, written.standardizedFileURL)
    }

    func testTheFilenameIsTheEmbeddedSessionID() throws {
        let url = try writeDatabase(steps: [(14, Self.userStepPayload(text: "hi"))])
        XCTAssertEqual(try codec.embeddedSessionID(at: url), conversationID)
    }

    func testDecodesUserAssistantAndSystemSteps() throws {
        let url = try writeDatabase(steps: [
            (14, Self.userStepPayload(text: "fix the tests")),
            (101, Self.systemStepPayload(text: "reconnected")),
            (15, Self.assistantStepPayload(text: "on it"))
        ])

        let entries = try codec.readNative(at: url)

        XCTAssertEqual(entries.count, 3)
        guard case let .userMessage(text, _) = entries[0] else {
            return XCTFail("expected a user message, got \(entries[0])")
        }
        XCTAssertEqual(text, "fix the tests")

        guard case let .systemNote(text, _) = entries[1] else {
            return XCTFail("expected a system note, got \(entries[1])")
        }
        XCTAssertEqual(text, "reconnected")

        guard case let .assistantMessage(text, _) = entries[2] else {
            return XCTFail("expected an assistant message, got \(entries[2])")
        }
        XCTAssertEqual(text, "on it")
    }

    func testDecodesAToolCallWithoutAMatchingResult() throws {
        let url = try writeDatabase(steps: [
            (132, Self.toolCallStepPayload(callID: "call_1", tool: "run_command", argumentsJSON: #"{"CommandLine":"pwd"}"#))
        ])

        let entries = try codec.readNative(at: url)

        XCTAssertEqual(entries.count, 1)
        guard case let .toolUse(id, tool, input, _) = entries[0] else {
            return XCTFail("expected a tool use, got \(entries[0])")
        }
        XCTAssertEqual(id, "call_1")
        XCTAssertEqual(tool, "run_command")
        XCTAssertEqual(String(data: input, encoding: .utf8), #"{"CommandLine":"pwd"}"#)
        // No .toolResult — ToolCallPairing (run by every real handoff)
        // synthesizes a placeholder for this, rather than the codec guessing
        // at a result field it never confidently mapped.
    }

    func testEmptyAndUnrecognisedStepsAreSkipped() throws {
        let url = try writeDatabase(steps: [
            (15, Self.assistantStepPayload(text: "")),
            (9999, Self.assistantStepPayload(text: "ignore me")),
            (15, Self.assistantStepPayload(text: "kept"))
        ])

        let entries = try codec.readNative(at: url)

        XCTAssertEqual(entries.count, 1)
        guard case let .assistantMessage(text, _) = entries[0] else {
            return XCTFail("expected an assistant message, got \(entries[0])")
        }
        XCTAssertEqual(text, "kept")
    }

    /// When `agy` routes through a thinking-capable model (e.g. Claude Sonnet
    /// via Cursor's inference API), the assistant step stores the full reasoning
    /// trace in field 20.1 and the clean visible response in field 20.8. The
    /// codec must return only field 20.8 so the companion app never receives
    /// the raw chain-of-thought.
    func testThinkingModelReasoningIsNotDecodedAsAssistantMessage() throws {
        let reasoning = "Let me carefully think through this problem step by step…"
        let response  = "The answer is 42."

        let url = try writeDatabase(steps: [
            (15, Self.thinkingAssistantStepPayload(reasoning: reasoning, response: response))
        ])

        let entries = try codec.readNative(at: url)

        XCTAssertEqual(entries.count, 1, "thinking step must produce exactly one assistant entry")
        guard case let .assistantMessage(text, _) = entries[0] else {
            return XCTFail("expected assistantMessage, got \(entries[0])")
        }
        XCTAssertEqual(text, response,
                       "codec must return field 20.8 (visible response), not field 20.1 (reasoning)")
        XCTAssertFalse(text.contains(reasoning),
                       "reasoning trace must not reach the companion app")
    }

    // MARK: - Discovery

    func testDiscoversAConversationStartedAfterLaunch() throws {
        let launchedAt = Date()
        try writeDatabase(steps: [(14, Self.userStepPayload(text: "do the thing"))])

        let found = try codec.discoverSession(
            workingDirectory: URL(fileURLWithPath: "/tmp/anything"),
            since: launchedAt.addingTimeInterval(-30)
        )

        XCTAssertEqual(found?.sessionID, conversationID)
        XCTAssertNotNil(found?.url)
    }

    func testIgnoresConversationsCreatedBeforeTheLaunch() throws {
        try writeDatabase(steps: [(14, Self.userStepPayload(text: "an older conversation"))])

        XCTAssertNil(try codec.discoverSession(
            workingDirectory: URL(fileURLWithPath: "/tmp/anything"),
            since: Date().addingTimeInterval(60)
        ))
    }

    func testIgnoresAConversationWithNoContent() throws {
        try writeDatabase(steps: [(101, Self.systemStepPayload(text: "reconnected"))])

        XCTAssertNil(try codec.discoverSession(
            workingDirectory: URL(fileURLWithPath: "/tmp/anything"),
            since: Date().addingTimeInterval(-30)
        ))
    }

    // MARK: - Writing

    func testWritesAConversationTheReaderCanReadBack() async throws {
        let target = AntigravityTranscriptCodec(brainDirectory: brain, now: { Date(timeIntervalSince1970: 1_790_000_000) })
        let sessionID = "11111111-2222-3333-4444-555555555555"

        let entries: [CanonicalEntry] = [
            .userMessage(text: "how do I run the tests", timestamp: Date()),
            .assistantMessage(text: "swift test", timestamp: Date()),
            .toolUse(id: "call_1", tool: "run_command", input: Data(#"{"CommandLine":"swift test"}"#.utf8), timestamp: Date())
        ]

        let handle = try await target.writeNative(
            target.sanitize(entries),
            workingDirectory: URL(fileURLWithPath: "/tmp/project"),
            sessionID: sessionID
        )

        XCTAssertEqual(handle.nativeSessionID, sessionID)
        let transcriptURL = try XCTUnwrap(handle.transcriptURL)

        XCTAssertEqual(try target.embeddedSessionID(at: transcriptURL), sessionID)

        let recovered = try target.readNative(at: transcriptURL)
        XCTAssertEqual(recovered.count, 1, "the whole history folds into one synthetic user step")
        guard case let .userMessage(text, _) = recovered[0] else {
            return XCTFail("expected a user message, got \(recovered[0])")
        }
        XCTAssertTrue(text.contains("how do I run the tests"))
        XCTAssertTrue(text.contains("swift test"))
        XCTAssertTrue(text.contains("ran run_command"), "sanitize folded the tool call into text")
    }

    func testWrittenConversationIsDiscoverableByThePinnedIdentity() async throws {
        let target = AntigravityTranscriptCodec(brainDirectory: brain)
        let sessionID = "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee"

        _ = try await target.writeNative(
            [.userMessage(text: "hello", timestamp: Date())],
            workingDirectory: URL(fileURLWithPath: "/tmp/project"),
            sessionID: sessionID
        )

        let located = try target.transcriptURL(sessionID: sessionID, workingDirectory: URL(fileURLWithPath: "/tmp/project"))
        XCTAssertNotNil(located)
        XCTAssertEqual(try target.embeddedSessionID(at: XCTUnwrap(located)), sessionID)
    }

    func testRemoveNativeStateDeletesTheDatabase() async throws {
        let target = AntigravityTranscriptCodec(brainDirectory: brain)
        let sessionID = "bbbbbbbb-cccc-dddd-eeee-ffffffffffff"
        let handle = try await target.writeNative(
            [.userMessage(text: "hello", timestamp: Date())],
            workingDirectory: URL(fileURLWithPath: "/tmp/project"),
            sessionID: sessionID
        )
        let file = try XCTUnwrap(handle.transcriptURL)
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.path))

        try target.removeNativeState(sessionID: sessionID, workingDirectory: URL(fileURLWithPath: "/tmp/project"))

        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
    }

    // MARK: - Registry

    func testTheShippingRegistryOffersAntigravityAsBothSourceAndTarget() {
        let registry = TranscriptCodecRegistry.default

        XCTAssertTrue(registry.readableAgents.contains(.antigravity))
        XCTAssertTrue(registry.writableAgents.contains(.antigravity))
        XCTAssertTrue(registry.handoffTargets(from: .claudeCode).contains(.antigravity))
        XCTAssertTrue(registry.handoffTargets(from: .antigravity).contains(.claudeCode))
    }
}

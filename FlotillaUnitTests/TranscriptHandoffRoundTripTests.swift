import XCTest
import SessionKit
import SQLite3
@testable import TranscriptKit

/// The whole feature in miniature: a Claude transcript on disk becomes a Codex
/// rollout that reads back as the same conversation. If this suite passes, the
/// transcode is sound and everything left is process and persistence work.
final class TranscriptHandoffRoundTripTests: XCTestCase {
    private var home: URL!
    private var workingDirectory: URL!
    private var claude: ClaudeTranscriptCodec!
    private var codex: CodexTranscriptCodec!

    private static let writeTime = Date(timeIntervalSince1970: 1_788_830_316)
    private let claudeSessionID = "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee"
    private let codexSessionID = "11111111-2222-3333-4444-555555555555"

    override func setUpWithError() throws {
        try super.setUpWithError()
        home = FileManager.default.temporaryDirectory
            .appendingPathComponent("RoundTripTests-\(UUID().uuidString)", isDirectory: true)
        workingDirectory = URL(fileURLWithPath: "/tmp/example-project")
        claude = ClaudeTranscriptCodec(homeDirectory: home)
        codex = CodexTranscriptCodec(homeDirectory: home, now: { Self.writeTime })
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: home)
        try super.tearDownWithError()
    }

    /// A realistic interrupted session: the user asked for something, the agent
    /// narrated, called a tool, got an answer, called a second tool — and was
    /// handed off before that one returned.
    private func writeClaudeTranscript() throws -> URL {
        let directory = home
            .appendingPathComponent(".claude/projects", isDirectory: true)
            .appendingPathComponent(ClaudeTranscriptCodec.projectSlug(for: workingDirectory), isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = directory.appendingPathComponent("\(claudeSessionID).jsonl")

        let lines = [
            #"{"type":"permission-mode","permissionMode":"default","sessionId":"\#(claudeSessionID)"}"#,
            #"{"type":"user","uuid":"u1","parentUuid":null,"sessionId":"\#(claudeSessionID)","timestamp":"2026-09-08T01:18:36Z","message":{"role":"user","content":"list the files"}}"#,
            #"{"type":"assistant","uuid":"a1","parentUuid":"u1","sessionId":"\#(claudeSessionID)","timestamp":"2026-09-08T01:18:37Z","message":{"role":"assistant","content":[{"type":"text","text":"looking"},{"type":"tool_use","id":"call_1","name":"Bash","input":{"command":"ls"}}]}}"#,
            #"{"type":"user","uuid":"u2","parentUuid":"a1","sessionId":"\#(claudeSessionID)","timestamp":"2026-09-08T01:18:38Z","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"call_1","content":"file.txt","is_error":false}]}}"#,
            #"{"type":"assistant","uuid":"a2","parentUuid":"u2","sessionId":"\#(claudeSessionID)","timestamp":"2026-09-08T01:18:39Z","message":{"role":"assistant","content":[{"type":"tool_use","id":"call_2","name":"Bash","input":{"command":"cat file.txt"}}]}}"#,
            #"{"type":"cost-state","sessionId":"\#(claudeSessionID)","totalCostUSD":0.02}"#
        ]
        try lines.joined(separator: "\n").write(to: file, atomically: true, encoding: .utf8)
        return file
    }

    func testClaudeTranscriptSurvivesTheMoveToCodex() async throws {
        let source = try writeClaudeTranscript()

        // Ownership check, as the handoff transaction will do it.
        XCTAssertEqual(try claude.embeddedSessionID(at: source), claudeSessionID)

        let read = try claude.readNative(at: source)
        XCTAssertTrue(read.hasConversationalContent)

        let marked = read.appendingHandoffMarker(from: .claudeCode, to: .codexCLI, at: Self.writeTime)
        let paired = ToolCallPairing.pair(marked)

        // The second tool call never returned, so it gets a placeholder rather
        // than being handed to the next provider unpaired.
        XCTAssertEqual(paired.synthesizedResults, 1)
        XCTAssertEqual(paired.droppedOrphanResults, 0)

        let handle = try await codex.writeNative(
            codex.sanitize(paired.entries),
            workingDirectory: workingDirectory,
            sessionID: codexSessionID
        )

        let recovered = try codex.readNative(at: XCTUnwrap(handle.transcriptURL))

        XCTAssertEqual(recovered.count, 6)
        guard case let .userMessage(opening, _) = recovered[0] else {
            return XCTFail("expected the user's opening message, got \(recovered[0])")
        }
        XCTAssertEqual(opening, "list the files")

        let toolNames: [String] = recovered.compactMap { entry in
            guard case let .toolUse(_, tool, _, _) = entry else { return nil }
            return tool
        }
        XCTAssertEqual(toolNames, ["Bash", "Bash"])

        guard case let .toolResult(_, lastOutput, isError, _) = recovered[5] else {
            return XCTFail("expected the synthesized result last, got \(recovered[5])")
        }
        // The explanation survives the move; the boolean does not. Codex's
        // `function_call_output` has nowhere to put an error flag, so it comes
        // back false — the reason the placeholder says what happened in words.
        XCTAssertEqual(lastOutput, ToolCallPairing.missingResultText)
        XCTAssertFalse(isError)
    }

    /// The receiving agent must be able to find what we wrote using only the
    /// id we pinned — that id is what the launch layer will resume by.
    func testTheWrittenRolloutIsDiscoverableByThePinnedIdentity() async throws {
        let source = try writeClaudeTranscript()
        let entries = try claude.readNative(at: source)
            .appendingHandoffMarker(from: .claudeCode, to: .codexCLI, at: Self.writeTime)

        _ = try await codex.writeNative(
            codex.sanitize(ToolCallPairing.pair(entries).entries),
            workingDirectory: workingDirectory,
            sessionID: codexSessionID
        )

        let located = try codex.transcriptURL(sessionID: codexSessionID, workingDirectory: workingDirectory)
        XCTAssertNotNil(located)
        XCTAssertEqual(try codex.embeddedSessionID(at: XCTUnwrap(located)), codexSessionID)
    }

    func testRegistryOffersCodexAsATargetForAClaudeSession() async {
        let readers: [any TranscriptReading] = [claude, codex]
        let writers: [any TranscriptWriting] = [claude, codex]
        let registry = TranscriptCodecRegistry(readers: readers, writers: writers)

        XCTAssertEqual(registry.handoffTargets(from: .claudeCode), [.codexCLI])
        XCTAssertEqual(registry.handoffTargets(from: .codexCLI), [.claudeCode])
        // An agent with no codec registered in *this* registry is neither a
        // source nor a target — the property that keeps an agent out of the
        // destination picker without anyone hardcoding the rule. OpenCode is
        // absent from this registry (and from `TranscriptCodecRegistry.default`
        // itself, pending its HTTP session API), unlike Antigravity, which is
        // both a source and a target in the shipping registry — see
        // `AntigravityTranscriptCodecTests`.
        XCTAssertTrue(registry.handoffTargets(from: .openCode).isEmpty)
        XCTAssertFalse(registry.writableAgents.contains(.openCode))
    }

    // MARK: - Antigravity

    private func writeAntigravityConversation(sessionID: String) throws -> URL {
        let antigravity = AntigravityTranscriptCodec(brainDirectory: home.appendingPathComponent(".gemini/antigravity-cli/brain", isDirectory: true))
        var db: OpaquePointer?
        let directory = home.appendingPathComponent(".gemini/antigravity-cli/conversations", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = directory.appendingPathComponent("\(sessionID).db")
        XCTAssertEqual(sqlite3_open_v2(file.path, &db, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE, nil), SQLITE_OK)
        defer { sqlite3_close(db) }
        sqlite3_exec(db, "CREATE TABLE `steps` (`idx` integer,`step_type` integer,`step_payload` blob, PRIMARY KEY (`idx`))", nil, nil, nil)

        func insert(idx: Int, type: Int, payload: Data) {
            var statement: OpaquePointer?
            sqlite3_prepare_v2(db, "INSERT INTO steps (idx, step_type, step_payload) VALUES (?, ?, ?)", -1, &statement, nil)
            sqlite3_bind_int(statement, 1, Int32(idx))
            sqlite3_bind_int(statement, 2, Int32(type))
            let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
            payload.withUnsafeBytes { raw in _ = sqlite3_bind_blob(statement, 3, raw.baseAddress, Int32(payload.count), transient) }
            sqlite3_step(statement)
            sqlite3_finalize(statement)
        }

        func step(type: Int, contentField: Int, text: String) -> Data {
            let envelope = AntigravityWireFormat.messageField(5, [
                AntigravityWireFormat.messageField(1, [AntigravityWireFormat.varintField(1, 1_789_000_000)])
            ])
            return AntigravityWireFormat.serialize([
                AntigravityWireFormat.varintField(1, UInt64(type)),
                envelope,
                AntigravityWireFormat.messageField(contentField, [AntigravityWireFormat.stringField(type == 14 ? 2 : 1, text)])
            ])
        }

        insert(idx: 0, type: 14, payload: step(type: 14, contentField: 19, text: "list the files"))
        insert(idx: 1, type: 15, payload: step(type: 15, contentField: 20, text: "on it, running ls"))
        try FileManager.default.createDirectory(
            at: home.appendingPathComponent(".gemini/antigravity-cli/brain/\(sessionID)", isDirectory: true),
            withIntermediateDirectories: true
        )
        return file
    }

    /// The write side is deliberately lossier than the Claude↔Codex round
    /// trip — see the doc comment on `AntigravityTranscriptCodec.writeNative`
    /// for why the whole history folds into one synthetic step rather than a
    /// matching sequence of Antigravity-shaped steps.
    func testClaudeTranscriptSurvivesTheMoveToAntigravity() async throws {
        let source = try writeClaudeTranscript()
        let antigravity = AntigravityTranscriptCodec(brainDirectory: home.appendingPathComponent(".gemini/antigravity-cli/brain", isDirectory: true))
        let antigravitySessionID = "22222222-3333-4444-5555-666666666666"

        let read = try claude.readNative(at: source)
        let marked = read.appendingHandoffMarker(from: .claudeCode, to: .antigravity, at: Self.writeTime)
        let paired = ToolCallPairing.pair(marked)

        let handle = try await antigravity.writeNative(
            antigravity.sanitize(paired.entries),
            workingDirectory: workingDirectory,
            sessionID: antigravitySessionID
        )

        XCTAssertEqual(handle.nativeSessionID, antigravitySessionID)
        let recovered = try antigravity.readNative(at: XCTUnwrap(handle.transcriptURL))

        XCTAssertEqual(recovered.count, 1, "the whole handoff folds into one synthetic user step")
        guard case let .userMessage(text, _) = recovered[0] else {
            return XCTFail("expected a user message, got \(recovered[0])")
        }
        XCTAssertTrue(text.contains("list the files"), "the opening request survives")
        XCTAssertTrue(text.contains("ran Bash"), "the tool call survives as folded text")
    }

    func testAntigravityConversationSurvivesTheMoveToClaude() async throws {
        let antigravitySessionID = "33333333-4444-5555-6666-777777777777"
        let source = try writeAntigravityConversation(sessionID: antigravitySessionID)
        let antigravity = AntigravityTranscriptCodec(brainDirectory: home.appendingPathComponent(".gemini/antigravity-cli/brain", isDirectory: true))

        XCTAssertEqual(try antigravity.embeddedSessionID(at: source), antigravitySessionID)
        let read = try antigravity.readNative(at: source)
        XCTAssertTrue(read.hasConversationalContent)

        let marked = read.appendingHandoffMarker(from: .antigravity, to: .claudeCode, at: Self.writeTime)
        let claudeSessionID = "44444444-5555-6666-7777-888888888888"
        let handle = try await claude.writeNative(
            claude.sanitize(marked),
            workingDirectory: workingDirectory,
            sessionID: claudeSessionID
        )

        let recovered = try claude.readNative(at: XCTUnwrap(handle.transcriptURL))
        XCTAssertEqual(recovered.count, 2)
        guard case let .userMessage(text, _) = recovered[0] else {
            return XCTFail("expected a user message, got \(recovered[0])")
        }
        XCTAssertEqual(text, "list the files")
    }

    func testTheShippingRegistryOffersAntigravityBothWays() {
        let registry = TranscriptCodecRegistry.default
        XCTAssertTrue(registry.handoffTargets(from: .claudeCode).contains(.antigravity))
        XCTAssertTrue(registry.handoffTargets(from: .antigravity).contains(.claudeCode))
    }
}

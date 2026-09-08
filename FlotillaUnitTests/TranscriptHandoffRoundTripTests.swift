import XCTest
import SessionKit
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

    func testClaudeTranscriptSurvivesTheMoveToCodex() throws {
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

        let handle = try codex.writeNative(
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
    func testTheWrittenRolloutIsDiscoverableByThePinnedIdentity() throws {
        let source = try writeClaudeTranscript()
        let entries = try claude.readNative(at: source)
            .appendingHandoffMarker(from: .claudeCode, to: .codexCLI, at: Self.writeTime)

        _ = try codex.writeNative(
            codex.sanitize(ToolCallPairing.pair(entries).entries),
            workingDirectory: workingDirectory,
            sessionID: codexSessionID
        )

        let located = try codex.transcriptURL(sessionID: codexSessionID, workingDirectory: workingDirectory)
        XCTAssertNotNil(located)
        XCTAssertEqual(try codex.embeddedSessionID(at: XCTUnwrap(located)), codexSessionID)
    }

    func testRegistryOffersCodexAsATargetForAClaudeSession() {
        let readers: [any TranscriptReading] = [claude, codex]
        let writers: [any TranscriptWriting] = [claude, codex]
        let registry = TranscriptCodecRegistry(readers: readers, writers: writers)

        XCTAssertEqual(registry.handoffTargets(from: .claudeCode), [.codexCLI])
        XCTAssertEqual(registry.handoffTargets(from: .codexCLI), [.claudeCode])
        // An agent with no codec registered is neither a source nor a target,
        // which is the property that keeps Antigravity out of the destination
        // picker without anyone hardcoding the rule.
        XCTAssertTrue(registry.handoffTargets(from: .antigravity).isEmpty)
        XCTAssertFalse(registry.writableAgents.contains(.antigravity))
    }
}

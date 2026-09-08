import XCTest
import SessionKit
@testable import TranscriptKit

/// Exercised against synthesized transcripts written into a temporary home
/// directory, matching the convention in `AgentSessionProviderTests` — no
/// checked-in fixtures, and never the developer's real `~/.claude`.
final class ClaudeTranscriptCodecTests: XCTestCase {
    private var home: URL!
    private var workingDirectory: URL!
    private var codec: ClaudeTranscriptCodec!

    private let sessionID = "11111111-2222-3333-4444-555555555555"

    override func setUpWithError() throws {
        try super.setUpWithError()
        home = FileManager.default.temporaryDirectory
            .appendingPathComponent("TranscriptKitTests-\(UUID().uuidString)", isDirectory: true)
        workingDirectory = URL(fileURLWithPath: "/tmp/example-project")
        codec = ClaudeTranscriptCodec(homeDirectory: home)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: home)
        try super.tearDownWithError()
    }

    /// Built from components rather than an epoch literal so the expectation
    /// states the timestamp the fixture actually contains.
    private static func utc(_ year: Int, _ month: Int, _ day: Int, _ hour: Int, _ minute: Int, _ second: Int) -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar.date(from: DateComponents(
            year: year, month: month, day: day, hour: hour, minute: minute, second: second
        ))!
    }

    @discardableResult
    private func writeTranscript(_ lines: [String], slug: String? = nil) throws -> URL {
        let directory = home
            .appendingPathComponent(".claude/projects", isDirectory: true)
            .appendingPathComponent(slug ?? ClaudeTranscriptCodec.projectSlug(for: workingDirectory), isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = directory.appendingPathComponent("\(sessionID).jsonl")
        try lines.joined(separator: "\n").write(to: file, atomically: true, encoding: .utf8)
        return file
    }

    // MARK: - Location

    func testProjectSlugReplacesEverySeparatorWithADash() {
        XCTAssertEqual(
            ClaudeTranscriptCodec.projectSlug(for: URL(fileURLWithPath: "/private/tmp/acme-queue/arm1")),
            "-private-tmp-acme-queue-arm1"
        )
    }

    /// `standardizedFileURL` resolves symlinks only for paths that *exist*, so
    /// standardizing here would silently relocate a session's transcript the
    /// first time its worktree was created — writing it where the agent does
    /// not look. The slug must be a function of the path and nothing else.
    func testProjectSlugDoesNotChangeWhenTheDirectoryComesIntoExistence() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("SlugStability-\(UUID().uuidString)", isDirectory: true)
        let beforeItExists = ClaudeTranscriptCodec.projectSlug(for: directory)

        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        XCTAssertEqual(ClaudeTranscriptCodec.projectSlug(for: directory), beforeItExists)
    }

    func testTranscriptURLResolvesViaTheSlugDirectory() throws {
        let written = try writeTranscript([#"{"type":"user","sessionId":"\#(sessionID)"}"#])
        let found = try codec.transcriptURL(sessionID: sessionID, workingDirectory: workingDirectory)
        XCTAssertEqual(found?.standardizedFileURL, written.standardizedFileURL)
    }

    /// The slug mapping is ambiguous and a session's `workingDirectory` can be
    /// rewritten after launch, so resolution must still succeed when the
    /// directory name does not match. The filename is the session id.
    func testTranscriptURLFallsBackToFilenameWhenSlugDoesNotMatch() throws {
        let written = try writeTranscript(
            [#"{"type":"user","sessionId":"\#(sessionID)"}"#],
            slug: "-somewhere-else-entirely"
        )
        let found = try codec.transcriptURL(sessionID: sessionID, workingDirectory: workingDirectory)
        XCTAssertEqual(found?.standardizedFileURL, written.standardizedFileURL)
    }

    func testTranscriptURLIsNilWhenNothingMatches() throws {
        try writeTranscript([#"{"type":"user","sessionId":"\#(sessionID)"}"#])
        XCTAssertNil(try codec.transcriptURL(sessionID: UUID().uuidString, workingDirectory: workingDirectory))
    }

    func testEmbeddedSessionIDIsReadFromTheFirstRecordThatCarriesOne() throws {
        let url = try writeTranscript([
            #"{"type":"mode","mode":"default"}"#,
            #"{"type":"user","sessionId":"\#(sessionID)","message":{"role":"user","content":"hi"}}"#
        ])
        XCTAssertEqual(try codec.embeddedSessionID(at: url), sessionID)
    }

    // MARK: - Reading

    func testReadsUserAndAssistantTurnsAndIgnoresSidecarRecords() throws {
        let url = try writeTranscript([
            #"{"type":"mode","mode":"default","sessionId":"\#(sessionID)"}"#,
            #"{"type":"cost-state","totalCostUSD":0.42}"#,
            #"{"type":"user","uuid":"u1","parentUuid":null,"timestamp":"2026-09-08T01:18:36.123Z","message":{"role":"user","content":"add a test"}}"#,
            #"{"type":"assistant","uuid":"a1","parentUuid":"u1","timestamp":"2026-09-08T01:18:40.000Z","message":{"role":"assistant","content":[{"type":"text","text":"on it"}]}}"#,
            #"{"type":"file-history-snapshot","messageId":"a1"}"#
        ])

        let entries = try codec.readNative(at: url)

        XCTAssertEqual(entries.count, 2)
        guard case let .userMessage(text, timestamp) = entries[0] else {
            return XCTFail("expected a user message, got \(entries[0])")
        }
        XCTAssertEqual(text, "add a test")
        XCTAssertEqual(
            timestamp.timeIntervalSince1970,
            Self.utc(2026, 9, 8, 1, 18, 36).timeIntervalSince1970 + 0.123,
            accuracy: 0.01
        )

        guard case let .assistantMessage(reply, _) = entries[1] else {
            return XCTFail("expected an assistant message, got \(entries[1])")
        }
        XCTAssertEqual(reply, "on it")
    }

    func testReadsToolUseAndToolResultBlocks() throws {
        let url = try writeTranscript([
            #"{"type":"assistant","uuid":"a1","timestamp":"2026-09-08T01:18:40Z","message":{"role":"assistant","content":[{"type":"text","text":"looking"},{"type":"tool_use","id":"call_1","name":"Bash","input":{"command":"ls"}}]}}"#,
            #"{"type":"user","uuid":"u2","timestamp":"2026-09-08T01:18:41Z","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"call_1","content":"file.txt","is_error":false}]}}"#
        ])

        let entries = try codec.readNative(at: url)

        XCTAssertEqual(entries.count, 3)
        guard case let .toolUse(id, tool, input, _) = entries[1] else {
            return XCTFail("expected a tool use, got \(entries[1])")
        }
        XCTAssertEqual(id, "call_1")
        XCTAssertEqual(tool, "Bash")
        let decoded = try XCTUnwrap(JSONSerialization.jsonObject(with: input) as? [String: Any])
        XCTAssertEqual(decoded["command"] as? String, "ls")

        guard case let .toolResult(toolUseID, output, isError, _) = entries[2] else {
            return XCTFail("expected a tool result, got \(entries[2])")
        }
        XCTAssertEqual(toolUseID, "call_1")
        XCTAssertEqual(output, "file.txt")
        XCTAssertFalse(isError)
    }

    /// A subagent's conversation has its own parent chain; splicing it into the
    /// main thread would interleave two histories into one unreadable list.
    func testSidechainRecordsAreExcluded() throws {
        let url = try writeTranscript([
            #"{"type":"user","isSidechain":false,"timestamp":"2026-09-08T01:18:36Z","message":{"role":"user","content":"main thread"}}"#,
            #"{"type":"user","isSidechain":true,"timestamp":"2026-09-08T01:18:37Z","message":{"role":"user","content":"subagent thread"}}"#
        ])

        let entries = try codec.readNative(at: url)

        XCTAssertEqual(entries.count, 1)
        guard case let .userMessage(text, _) = entries[0] else {
            return XCTFail("expected a user message, got \(entries[0])")
        }
        XCTAssertEqual(text, "main thread")
    }

    /// These formats gain record and block types between upstream releases, so
    /// a reader that fails on the unfamiliar would break on every update.
    func testUnknownBlockTypesAndMalformedLinesAreSkippedNotFatal() throws {
        let url = try writeTranscript([
            "not json at all",
            #"{"type":"assistant","timestamp":"2026-09-08T01:18:40Z","message":{"role":"assistant","content":[{"type":"thinking","thinking":"hmm"},{"type":"text","text":"answer"}]}}"#,
            ""
        ])

        let entries = try codec.readNative(at: url)

        XCTAssertEqual(entries.count, 1)
        guard case let .assistantMessage(text, _) = entries[0] else {
            return XCTFail("expected an assistant message, got \(entries[0])")
        }
        XCTAssertEqual(text, "answer")
    }

    func testTranscriptWithoutConversationIsReportedAsSuch() throws {
        let url = try writeTranscript([
            #"{"type":"mode","mode":"default"}"#,
            #"{"type":"cost-state","totalCostUSD":0}"#
        ])

        XCTAssertFalse(try codec.readNative(at: url).hasConversationalContent)
    }
}

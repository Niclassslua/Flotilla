import XCTest
import SessionKit
@testable import TranscriptKit

/// The write half of the Claude codec. The two invariants under test — an
/// unbroken parent chain and one record per turn — are what Claude checks when
/// it loads a transcript, so a regression here is a session that will not open.
final class ClaudeTranscriptWriterTests: XCTestCase {
    private var home: URL!
    private var workingDirectory: URL!
    private var codec: ClaudeTranscriptCodec!

    private static let epoch = Date(timeIntervalSince1970: 1_788_830_316)
    private let sessionID = "11111111-2222-3333-4444-555555555555"

    override func setUpWithError() throws {
        try super.setUpWithError()
        home = FileManager.default.temporaryDirectory
            .appendingPathComponent("ClaudeWriterTests-\(UUID().uuidString)", isDirectory: true)
        workingDirectory = URL(fileURLWithPath: "/tmp/example-project")
        codec = ClaudeTranscriptCodec(homeDirectory: home, gitBranch: "main")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: home)
        try super.tearDownWithError()
    }

    private func write(_ entries: [CanonicalEntry]) async throws -> [[String: Any]] {
        let handle = try await codec.writeNative(entries, workingDirectory: workingDirectory, sessionID: sessionID)
        let url = try XCTUnwrap(handle.transcriptURL)
        return try ClaudeTranscriptCodec.lines(of: url).compactMap { ClaudeTranscriptCodec.decodeObject($0) }
    }

    // MARK: - Structure

    func testWritesLeadingPermissionModeRecordAndNamesTheFileBySessionID() async throws {
        let handle = try await codec.writeNative(
            [.userMessage(text: "hi", timestamp: Self.epoch)],
            workingDirectory: workingDirectory,
            sessionID: sessionID
        )

        let url = try XCTUnwrap(handle.transcriptURL)
        XCTAssertEqual(url.lastPathComponent, "\(sessionID).jsonl")
        XCTAssertEqual(handle.nativeSessionID, sessionID)

        let records = try ClaudeTranscriptCodec.lines(of: url).compactMap { ClaudeTranscriptCodec.decodeObject($0) }
        XCTAssertEqual(records.first?["type"] as? String, "permission-mode")
    }

    /// Claude refuses a transcript whose chain is broken, so every
    /// conversational record must point at the one before it.
    func testParentChainIsUnbrokenAndStartsAtNull() async throws {
        let records = try await write([
            .userMessage(text: "one", timestamp: Self.epoch),
            .assistantMessage(text: "two", timestamp: Self.epoch),
            .userMessage(text: "three", timestamp: Self.epoch)
        ])

        let chained = records.filter { ($0["type"] as? String) == "user" || ($0["type"] as? String) == "assistant" }
        XCTAssertEqual(chained.count, 3)

        XCTAssertTrue(chained[0]["parentUuid"] is NSNull, "the first turn has no parent")

        var expectedParent = try XCTUnwrap(chained[0]["uuid"] as? String)
        for record in chained.dropFirst() {
            XCTAssertEqual(record["parentUuid"] as? String, expectedParent)
            expectedParent = try XCTUnwrap(record["uuid"] as? String)
        }
    }

    func testAssistantTextAndToolCallsCoalesceIntoOneRecord() async throws {
        let records = try await write([
            .assistantMessage(text: "looking", timestamp: Self.epoch),
            .toolUse(id: "call_1", tool: "Bash", input: Data(#"{"command":"ls"}"#.utf8), timestamp: Self.epoch),
            .toolUse(id: "call_2", tool: "Read", input: Data(#"{"path":"a.txt"}"#.utf8), timestamp: Self.epoch)
        ])

        let assistants = records.filter { $0["type"] as? String == "assistant" }
        XCTAssertEqual(assistants.count, 1, "one agent turn is one record")

        let message = try XCTUnwrap(assistants[0]["message"] as? [String: Any])
        let blocks = try XCTUnwrap(message["content"] as? [[String: Any]])
        XCTAssertEqual(blocks.map { $0["type"] as? String }, ["text", "tool_use", "tool_use"])

        // The tool's arguments go back as a nested object, not a JSON string.
        let input = try XCTUnwrap(blocks[1]["input"] as? [String: Any])
        XCTAssertEqual(input["command"] as? String, "ls")
    }

    /// Tool results and the user's next message are one turn. Splitting them
    /// would put an empty user turn between the results and the reply.
    func testToolResultsAndAFollowingUserMessageShareOneRecord() async throws {
        let records = try await write([
            .toolResult(toolUseID: "call_1", output: "file.txt", isError: false, timestamp: Self.epoch),
            .toolResult(toolUseID: "call_2", output: "boom", isError: true, timestamp: Self.epoch),
            .userMessage(text: "now fix it", timestamp: Self.epoch)
        ])

        let users = records.filter { $0["type"] as? String == "user" }
        XCTAssertEqual(users.count, 1)

        let message = try XCTUnwrap(users[0]["message"] as? [String: Any])
        let blocks = try XCTUnwrap(message["content"] as? [[String: Any]])
        XCTAssertEqual(blocks.map { $0["type"] as? String }, ["tool_result", "tool_result", "text"])
        XCTAssertNil(blocks[0]["is_error"], "a successful result carries no error flag")
        XCTAssertEqual(blocks[1]["is_error"] as? Bool, true)
    }

    func testSystemNotesAreWrittenOutsideTheParentChain() async throws {
        let records = try await write([
            .userMessage(text: "one", timestamp: Self.epoch),
            .systemNote(text: "a notice", timestamp: Self.epoch),
            .userMessage(text: "two", timestamp: Self.epoch)
        ])

        let system = try XCTUnwrap(records.first { $0["type"] as? String == "system" })
        XCTAssertEqual(system["subtype"] as? String, "local_command")
        XCTAssertNil(system["uuid"], "a system note is not a turn and holds no chain link")

        // The two real turns remain directly linked across it.
        let users = records.filter { $0["type"] as? String == "user" }
        XCTAssertEqual(users[1]["parentUuid"] as? String, users[0]["uuid"] as? String)
    }

    func testHandoffMarkerIsNotWritten() async throws {
        let records = try await write([
            .userMessage(text: "one", timestamp: Self.epoch),
            .handoffMarker(from: .codexCLI, to: .claudeCode, reason: "user-requested", timestamp: Self.epoch)
        ])

        XCTAssertEqual(records.filter { $0["type"] as? String == "user" }.count, 1)
        XCTAssertFalse(records.contains { $0["type"] as? String == "handoff_marker" })
    }

    // MARK: - Round trip

    func testRoundTripsItsOwnOutput() async throws {
        let entries: [CanonicalEntry] = [
            .userMessage(text: "list the files", timestamp: Self.epoch),
            .assistantMessage(text: "looking", timestamp: Self.epoch),
            .toolUse(id: "call_1", tool: "Bash", input: Data(#"{"command":"ls"}"#.utf8), timestamp: Self.epoch),
            .toolResult(toolUseID: "call_1", output: "file.txt", isError: false, timestamp: Self.epoch),
            .userMessage(text: "thanks", timestamp: Self.epoch)
        ]

        let handle = try await codec.writeNative(entries, workingDirectory: workingDirectory, sessionID: sessionID)
        let recovered = try codec.readNative(at: XCTUnwrap(handle.transcriptURL))

        XCTAssertEqual(recovered, entries)
        XCTAssertEqual(try codec.embeddedSessionID(at: XCTUnwrap(handle.transcriptURL)), sessionID)
    }

    // MARK: - Move-out

    func testRemoveNativeStateClearsTheTranscriptAndItsSidecars() async throws {
        let handle = try await codec.writeNative(
            [.userMessage(text: "hi", timestamp: Self.epoch)],
            workingDirectory: workingDirectory,
            sessionID: sessionID
        )
        let transcript = try XCTUnwrap(handle.transcriptURL)

        let claude = home.appendingPathComponent(".claude", isDirectory: true)
        let todos = claude.appendingPathComponent("todos", isDirectory: true)
        let tasks = claude.appendingPathComponent("tasks/\(sessionID)", isDirectory: true)
        try FileManager.default.createDirectory(at: todos, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: tasks, withIntermediateDirectories: true)
        let todoFile = todos.appendingPathComponent("\(sessionID)-agent-\(sessionID).json")
        try "[]".write(to: todoFile, atomically: true, encoding: .utf8)

        try codec.removeNativeState(sessionID: sessionID, workingDirectory: workingDirectory)

        XCTAssertFalse(FileManager.default.fileExists(atPath: transcript.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: todoFile.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: tasks.path))
        // Sidecars that never existed are not an error.
        XCTAssertNoThrow(try codec.removeNativeState(sessionID: sessionID, workingDirectory: workingDirectory))
    }
}

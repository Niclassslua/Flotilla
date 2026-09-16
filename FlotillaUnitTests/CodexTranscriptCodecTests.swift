import XCTest
import SessionKit
@testable import TranscriptKit

final class CodexTranscriptCodecTests: XCTestCase {
    private var home: URL!
    private var workingDirectory: URL!
    private var codec: CodexTranscriptCodec!

    /// 2026-09-08T01:18:36Z — fixed so the rollout's directory and filename are
    /// deterministic and can be asserted literally.
    private static let writeTime = Date(timeIntervalSince1970: 1_788_830_316)
    private let sessionID = "11111111-2222-3333-4444-555555555555"

    override func setUpWithError() throws {
        try super.setUpWithError()
        home = FileManager.default.temporaryDirectory
            .appendingPathComponent("CodexCodecTests-\(UUID().uuidString)", isDirectory: true)
        workingDirectory = URL(fileURLWithPath: "/tmp/example-project")
        codec = CodexTranscriptCodec(homeDirectory: home, now: { Self.writeTime })
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: home)
        try super.tearDownWithError()
    }

    private func records(at url: URL) throws -> [[String: Any]] {
        try CodexTranscriptCodec.lines(of: url).compactMap { CodexTranscriptCodec.decodeObject($0) }
    }

    private func payloadTypes(in records: [[String: Any]], ofRecordType type: String) -> [String] {
        records
            .filter { $0["type"] as? String == type }
            .compactMap { ($0["payload"] as? [String: Any])?["type"] as? String }
    }

    // MARK: - Layout

    func testWritesIntoDateNestedDirectoryWithSessionIDInTheFilename() async throws {
        let handle = try await codec.writeNative(
            [.userMessage(text: "hello", timestamp: Self.writeTime)],
            workingDirectory: workingDirectory,
            sessionID: sessionID
        )

        let url = try XCTUnwrap(handle.transcriptURL)
        XCTAssertEqual(url.lastPathComponent, "rollout-2026-09-08T01-18-36-\(sessionID).jsonl")
        XCTAssertEqual(
            url.deletingLastPathComponent().path,
            home.appendingPathComponent(".codex/sessions/2026/09/08").path
        )
        // The id Codex resumes by is the one we pinned, not one it minted.
        XCTAssertEqual(handle.nativeSessionID, sessionID)
    }

    func testRejectsASessionIDThatIsNotAUUID() async {
        do {
            _ = try await codec.writeNative([], workingDirectory: workingDirectory, sessionID: "not-a-uuid")
            XCTFail("expected an invalid session id to be refused")
        } catch {
            XCTAssertEqual(error as? TranscriptCodecError, .invalidSessionID("not-a-uuid"))
        }
    }

    func testHeaderRecordsComeFirstAndCarryTheSessionIdentity() async throws {
        let handle = try await codec.writeNative(
            [.userMessage(text: "hello", timestamp: Self.writeTime)],
            workingDirectory: workingDirectory,
            sessionID: sessionID
        )
        let parsed = try records(at: XCTUnwrap(handle.transcriptURL))

        XCTAssertEqual(parsed.first?["type"] as? String, "session_meta")
        XCTAssertEqual(parsed.dropFirst().first?["type"] as? String, "turn_context")

        let meta = try XCTUnwrap(parsed.first?["payload"] as? [String: Any])
        XCTAssertEqual(meta["id"] as? String, sessionID)
        XCTAssertEqual(meta["cwd"] as? String, workingDirectory.path)
        XCTAssertEqual(meta["originator"] as? String, "codex-tui")
        XCTAssertEqual(meta["source"] as? String, "cli")
    }

    // MARK: - The two audiences

    /// A handed-off transcript must feed the model *and* the TUI's scrollback.
    /// Without the mirror the user resumes into a blank screen.
    func testHandoffMarkerAddsTUIMirrorRecords() async throws {
        let entries: [CanonicalEntry] = [
            .userMessage(text: "add a test", timestamp: Self.writeTime),
            .assistantMessage(text: "done", timestamp: Self.writeTime),
            .handoffMarker(from: .claudeCode, to: .codexCLI, reason: "user-requested", timestamp: Self.writeTime)
        ]

        let handle = try await codec.writeNative(entries, workingDirectory: workingDirectory, sessionID: sessionID)
        let parsed = try records(at: XCTUnwrap(handle.transcriptURL))

        XCTAssertEqual(payloadTypes(in: parsed, ofRecordType: "event_msg"), ["user_message", "agent_message"])
        XCTAssertEqual(payloadTypes(in: parsed, ofRecordType: "response_item"), ["message", "message"])
    }

    /// An ordinary write — one Codex itself would have produced — must not
    /// duplicate turns, or the scrollback shows everything twice.
    func testWithoutHandoffMarkerNoMirrorIsWritten() async throws {
        let entries: [CanonicalEntry] = [
            .userMessage(text: "add a test", timestamp: Self.writeTime),
            .assistantMessage(text: "done", timestamp: Self.writeTime)
        ]

        let handle = try await codec.writeNative(entries, workingDirectory: workingDirectory, sessionID: sessionID)
        let parsed = try records(at: XCTUnwrap(handle.transcriptURL))

        XCTAssertTrue(payloadTypes(in: parsed, ofRecordType: "event_msg").isEmpty)
        XCTAssertEqual(payloadTypes(in: parsed, ofRecordType: "response_item"), ["message", "message"])
    }

    // MARK: - Tool calls

    func testToolCallsAreWrittenWithArgumentsAsAJSONString() async throws {
        let entries: [CanonicalEntry] = [
            .toolUse(id: "call_1", tool: "shell", input: Data(#"{"command":"ls"}"#.utf8), timestamp: Self.writeTime),
            .toolResult(toolUseID: "call_1", output: "file.txt", isError: false, timestamp: Self.writeTime)
        ]

        let handle = try await codec.writeNative(entries, workingDirectory: workingDirectory, sessionID: sessionID)
        let parsed = try records(at: XCTUnwrap(handle.transcriptURL))

        XCTAssertEqual(payloadTypes(in: parsed, ofRecordType: "response_item"), ["function_call", "function_call_output"])

        let call = try XCTUnwrap(parsed.first { ($0["payload"] as? [String: Any])?["type"] as? String == "function_call" })
        let payload = try XCTUnwrap(call["payload"] as? [String: Any])
        XCTAssertEqual(payload["call_id"] as? String, "call_1")
        XCTAssertEqual(payload["name"] as? String, "shell")
        // A JSON *string*, not a nested object — Codex will not accept an object.
        XCTAssertEqual(payload["arguments"] as? String, #"{"command":"ls"}"#)
    }

    /// Codex draws tool activity from `CommandExecution` items built out of
    /// live process state we do not have, so carried-over tool calls are
    /// mirrored as commentary. Without this the resumed scrollback shows the
    /// talking but none of the doing.
    func testToolActivityIsMirroredAsCommentaryForTheTUI() async throws {
        let entries: [CanonicalEntry] = [
            .toolUse(id: "call_1", tool: "Bash", input: Data(#"{"command":"ls -la"}"#.utf8), timestamp: Self.writeTime),
            .toolResult(toolUseID: "call_1", output: "file.txt", isError: false, timestamp: Self.writeTime),
            .toolUse(id: "call_2", tool: "Read", input: Data(#"{"file_path":"README.md"}"#.utf8), timestamp: Self.writeTime),
            .toolResult(toolUseID: "call_2", output: "boom, it failed", isError: true, timestamp: Self.writeTime),
            .handoffMarker(from: .claudeCode, to: .codexCLI, reason: "user-requested", timestamp: Self.writeTime)
        ]

        let handle = try await codec.writeNative(entries, workingDirectory: workingDirectory, sessionID: sessionID)
        let parsed = try records(at: XCTUnwrap(handle.transcriptURL))

        let commentary: [String] = parsed.compactMap { record in
            guard record["type"] as? String == "event_msg",
                  let payload = record["payload"] as? [String: Any],
                  payload["phase"] as? String == "commentary"
            else { return nil }
            return payload["message"] as? String
        }

        XCTAssertEqual(commentary.count, 3, "two calls and the one failure")
        XCTAssertTrue(commentary[0].contains("Bash"))
        XCTAssertTrue(commentary[0].contains("ls -la"), "the command a human would recognise, not raw JSON")
        XCTAssertTrue(commentary[1].contains("README.md"))
        XCTAssertTrue(commentary[2].contains("boom, it failed"), "a failed tool is worth showing")

        // The model still reads the real records, not the commentary.
        XCTAssertEqual(
            payloadTypes(in: parsed, ofRecordType: "response_item"),
            ["function_call", "function_call_output", "function_call", "function_call_output"]
        )
    }

    func testWithoutAHandoffMarkerToolActivityIsNotMirrored() async throws {
        let entries: [CanonicalEntry] = [
            .toolUse(id: "call_1", tool: "Bash", input: Data(#"{"command":"ls"}"#.utf8), timestamp: Self.writeTime),
            .toolResult(toolUseID: "call_1", output: "nope", isError: true, timestamp: Self.writeTime)
        ]

        let handle = try await codec.writeNative(entries, workingDirectory: workingDirectory, sessionID: sessionID)
        let parsed = try records(at: XCTUnwrap(handle.transcriptURL))

        XCTAssertTrue(parsed.filter { $0["type"] as? String == "event_msg" }.isEmpty)
    }

    func testCommentaryIsNotReadBackAsConversation() async throws {
        let entries: [CanonicalEntry] = [
            .toolUse(id: "call_1", tool: "Bash", input: Data(#"{"command":"ls"}"#.utf8), timestamp: Self.writeTime),
            .toolResult(toolUseID: "call_1", output: "file.txt", isError: false, timestamp: Self.writeTime),
            .handoffMarker(from: .claudeCode, to: .codexCLI, reason: "user-requested", timestamp: Self.writeTime)
        ]

        let handle = try await codec.writeNative(entries, workingDirectory: workingDirectory, sessionID: sessionID)
        let recovered = try codec.readNative(at: XCTUnwrap(handle.transcriptURL))

        // Round-trip stability: mirroring must not grow the conversation.
        XCTAssertEqual(recovered, [
            .toolUse(id: "call_1", tool: "Bash", input: Data(#"{"command":"ls"}"#.utf8), timestamp: Self.writeTime),
            .toolResult(toolUseID: "call_1", output: "file.txt", isError: false, timestamp: Self.writeTime)
        ])
    }

    // MARK: - Sanitising

    func testSanitizeDropsImagesWhichCodexCannotRepresent() async {
        let entries: [CanonicalEntry] = [
            .userMessage(text: "look", timestamp: Self.writeTime),
            .image(mimeType: "image/png", base64: "AAAA", filename: nil, timestamp: Self.writeTime)
        ]

        XCTAssertEqual(codec.sanitize(entries), [.userMessage(text: "look", timestamp: Self.writeTime)])
    }

    // MARK: - Viewed images

    /// Codex has no place to embed image bytes in a `response_item`; the only
    /// structured record of a `view_image` call is the TUI's `ImageView`
    /// `event_msg`, which carries just a file path. Reading it back must
    /// resolve that path into an inline, downsampled image.
    func testViewedImageIsReadFromDiskAsAnInlineImage() async throws {
        let handle = try await codec.writeNative(
            [.userMessage(text: "take a look", timestamp: Self.writeTime)],
            workingDirectory: workingDirectory,
            sessionID: sessionID
        )
        let url = try XCTUnwrap(handle.transcriptURL)

        let pngPath = home.appendingPathComponent("screenshot.png")
        // A minimal 1x1 PNG — enough for ImageIO to decode and re-encode.
        let onePixelPNG = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAIAAACQd1PeAAAADElEQVR4nGP4z8AAAAMBAQDJ/pLvAAAAAElFTkSuQmCC")!
        try onePixelPNG.write(to: pngPath)

        let record = #"""
        {"timestamp":"2026-09-08T01:18:36Z","type":"event_msg","payload":{"type":"item_completed","item":{"type":"ImageView","id":"exec-1","path":"file://\#(pngPath.path)"}}}
        """#
        let injected = try String(contentsOf: url, encoding: .utf8) + "\n" + record
        try injected.write(to: url, atomically: true, encoding: .utf8)

        let recovered = try codec.readNative(at: url)
        XCTAssertEqual(recovered.count, 2)
        guard case .image(let mimeType, let base64, _, _) = recovered.last else {
            return XCTFail("expected the second entry to be an image")
        }
        XCTAssertEqual(mimeType, "image/jpeg")
        XCTAssertFalse(base64.isEmpty)
        XCTAssertNotNil(Data(base64Encoded: base64))
    }

    /// A path that no longer exists on disk (a temp screenshot already
    /// cleaned up) must be skipped rather than fail the whole read.
    func testViewedImageWithAMissingFileIsSkipped() async throws {
        let handle = try await codec.writeNative(
            [.userMessage(text: "take a look", timestamp: Self.writeTime)],
            workingDirectory: workingDirectory,
            sessionID: sessionID
        )
        let url = try XCTUnwrap(handle.transcriptURL)

        let record = #"{"timestamp":"2026-09-08T01:18:36Z","type":"event_msg","payload":{"type":"item_completed","item":{"type":"ImageView","id":"exec-1","path":"file:///tmp/does-not-exist-\#(sessionID).png"}}}"#
        let injected = try String(contentsOf: url, encoding: .utf8) + "\n" + record
        try injected.write(to: url, atomically: true, encoding: .utf8)

        XCTAssertEqual(try codec.readNative(at: url), [.userMessage(text: "take a look", timestamp: Self.writeTime)])
    }

    func testFunctionCallOutputWithInputImageIsReadAsToolResultAndImage() async throws {
        let handle = try await codec.writeNative(
            [.userMessage(text: "take a screenshot", timestamp: Self.writeTime)],
            workingDirectory: workingDirectory,
            sessionID: sessionID
        )
        let url = try XCTUnwrap(handle.transcriptURL)

        // Minimal 1x1 PNG data URI
        let dataURI = "data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAIAAACQd1PeAAAADElEQVR4nGP4z8AAAAMBAQDJ/pLvAAAAAElFTkSuQmCC"
        let record = """
        {"timestamp":"2026-09-08T01:18:36Z","type":"response_item","payload":{"type":"function_call_output","call_id":"call_1","output":[{"type":"input_image","image_url":"\(dataURI)"},{"type":"text","text":"Captured screen"}]}}
        """
        let injected = try String(contentsOf: url, encoding: .utf8) + "\n" + record
        try injected.write(to: url, atomically: true, encoding: .utf8)

        let recovered = try codec.readNative(at: url)
        XCTAssertEqual(recovered.count, 3)
        XCTAssertEqual(recovered[0], .userMessage(text: "take a screenshot", timestamp: Self.writeTime))
        XCTAssertEqual(recovered[1], .toolResult(toolUseID: "call_1", output: "Captured screen", isError: false, timestamp: Self.writeTime))
        guard case .image(let mimeType, let base64, _, _) = recovered[2] else {
            return XCTFail("expected the third entry to be an image")
        }
        XCTAssertEqual(mimeType, "image/jpeg")
        XCTAssertFalse(base64.isEmpty)
    }

    // MARK: - Reading back

    func testRoundTripsItsOwnOutput() async throws {
        let entries: [CanonicalEntry] = [
            .userMessage(text: "add a test", timestamp: Self.writeTime),
            .assistantMessage(text: "looking", timestamp: Self.writeTime),
            .toolUse(id: "call_1", tool: "shell", input: Data(#"{"command":"ls"}"#.utf8), timestamp: Self.writeTime),
            .toolResult(toolUseID: "call_1", output: "file.txt", isError: false, timestamp: Self.writeTime)
        ]

        let handle = try await codec.writeNative(entries, workingDirectory: workingDirectory, sessionID: sessionID)
        let recovered = try codec.readNative(at: XCTUnwrap(handle.transcriptURL))

        XCTAssertEqual(recovered, entries)
    }

    /// The mirror exists for the TUI only; reading must not see each turn twice.
    func testReadingIgnoresTheTUIMirror() async throws {
        let entries: [CanonicalEntry] = [
            .userMessage(text: "one", timestamp: Self.writeTime),
            .assistantMessage(text: "two", timestamp: Self.writeTime),
            .handoffMarker(from: .claudeCode, to: .codexCLI, reason: "user-requested", timestamp: Self.writeTime)
        ]

        let handle = try await codec.writeNative(entries, workingDirectory: workingDirectory, sessionID: sessionID)
        let recovered = try codec.readNative(at: XCTUnwrap(handle.transcriptURL))

        XCTAssertEqual(recovered, [
            .userMessage(text: "one", timestamp: Self.writeTime),
            .assistantMessage(text: "two", timestamp: Self.writeTime)
        ])
    }

    func testReasoningItemsAreNeverWrittenAndAreSkippedWhenRead() async throws {
        let handle = try await codec.writeNative(
            [.assistantMessage(text: "answer", timestamp: Self.writeTime)],
            workingDirectory: workingDirectory,
            sessionID: sessionID
        )
        let url = try XCTUnwrap(handle.transcriptURL)

        XCTAssertFalse(payloadTypes(in: try records(at: url), ofRecordType: "response_item").contains("reasoning"))

        // A reasoning item that arrives from Codex's own file is ignored: its
        // encrypted payload is bound to the turn that produced it.
        let injected = try String(contentsOf: url, encoding: .utf8)
            + "\n" + #"{"timestamp":"2026-09-08T01:18:36Z","type":"response_item","payload":{"type":"reasoning","summary":[],"encrypted_content":"opaque"}}"#
        try injected.write(to: url, atomically: true, encoding: .utf8)

        XCTAssertEqual(try codec.readNative(at: url), [.assistantMessage(text: "answer", timestamp: Self.writeTime)])
    }

    /// Codex injects `<turn_aborted>…</turn_aborted>` as a plain user-role
    /// message after a stop. Read literally it would render as if the human
    /// typed raw XML tags; it must come back as a system note instead.
    func testTurnAbortedControlMessageIsReadAsASystemNote() async throws {
        let handle = try await codec.writeNative(
            [.userMessage(text: "ignored", timestamp: Self.writeTime)],
            workingDirectory: workingDirectory,
            sessionID: sessionID
        )
        let url = try XCTUnwrap(handle.transcriptURL)

        let record = #"{"timestamp":"2026-09-08T01:18:36Z","type":"response_item","payload":{"type":"message","role":"user","content":[{"type":"input_text","text":"<turn_aborted> The previous turn was interrupted on purpose. </turn_aborted>"}]}}"#
        let injected = try String(contentsOf: url, encoding: .utf8) + "\n" + record
        try injected.write(to: url, atomically: true, encoding: .utf8)

        XCTAssertEqual(try codec.readNative(at: url), [
            .userMessage(text: "ignored", timestamp: Self.writeTime),
            .systemNote(text: "The previous turn was interrupted on purpose.", timestamp: Self.writeTime)
        ])
    }

    // MARK: - Location

    func testLocatesAndIdentifiesAWrittenTranscript() async throws {
        let handle = try await codec.writeNative(
            [.userMessage(text: "hello", timestamp: Self.writeTime)],
            workingDirectory: workingDirectory,
            sessionID: sessionID
        )

        let found = try codec.transcriptURL(sessionID: sessionID, workingDirectory: workingDirectory)
        XCTAssertEqual(found?.standardizedFileURL, try XCTUnwrap(handle.transcriptURL).standardizedFileURL)
        XCTAssertEqual(try codec.embeddedSessionID(at: XCTUnwrap(found)), sessionID)
    }

    func testRemoveNativeStateDeletesTheRollout() async throws {
        let handle = try await codec.writeNative(
            [.userMessage(text: "hello", timestamp: Self.writeTime)],
            workingDirectory: workingDirectory,
            sessionID: sessionID
        )
        let url = try XCTUnwrap(handle.transcriptURL)

        try codec.removeNativeState(sessionID: sessionID, workingDirectory: workingDirectory)

        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
        // Removing state for a session that has none is not an error.
        XCTAssertNoThrow(try codec.removeNativeState(sessionID: sessionID, workingDirectory: workingDirectory))
    }
}

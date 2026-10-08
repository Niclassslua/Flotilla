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

    /// Slug mapping is path-only (separators → dashes; existence must not relocate
    /// a session), and URL resolution must find the file via the slug directory,
    /// fall back to the session-id filename when the slug diverges, or return nil.
    func testProjectSlugAndTranscriptURLDiscovery() throws {
        struct Case {
            let name: String
            let needsFreshHome: Bool
            let run: () throws -> Void
        }

        let cases: [Case] = [
            Case(name: "separators become dashes", needsFreshHome: false) {
                XCTAssertEqual(
                    ClaudeTranscriptCodec.projectSlug(for: URL(fileURLWithPath: "/private/tmp/acme-queue/arm1")),
                    "-private-tmp-acme-queue-arm1"
                )
            },
            // Observed on Claude Code 2.1.291 (`~/.claude/projects`): every
            // non-alphanumeric becomes a dash — a Flotilla worktree lives under
            // "Application Support".
            Case(name: "spaces, dots and symbols become dashes", needsFreshHome: false) {
                XCTAssertEqual(
                    ClaudeTranscriptCodec.projectSlug(for: URL(fileURLWithPath: "/Users/dev/Library/Application Support/Flotilla/Worktrees/flotilla/fix.v2_x+y")),
                    "-Users-dev-Library-Application-Support-Flotilla-Worktrees-flotilla-fix-v2-x-y"
                )
            },
            // The directory Claude 2.1.291 created for this exact path: cut to
            // 200 characters, then `-` and a hash of the path.
            Case(name: "long paths are truncated with Claude's hash", needsFreshHome: false) {
                let path = "/private/tmp/claude-501/-Users-niclasfrey-Library-Application-Support-Flotilla-Worktrees-flotilla-i-would-like-to-build-a-eb29472b/340DF155-33AA-48D5-93BB-0FE0C8A1B104/scratchpad/probe-claude/Slug Test.v2_dir+x"
                XCTAssertEqual(
                    ClaudeTranscriptCodec.projectSlug(for: URL(fileURLWithPath: path)),
                    "-private-tmp-claude-501--Users-niclasfrey-Library-Application-Support-Flotilla-Worktrees-flotilla-i-would-like-to-build-a-eb29472b-340DF155-33AA-48D5-93BB-0FE0C8A1B104-scratchpad-probe-claude-Slug-Tes-5lsqn4"
                )
            },
            // `standardizedFileURL` resolves symlinks only for paths that *exist*,
            // so standardizing here would silently relocate a session's transcript
            // the first time its worktree was created — writing it where the agent
            // does not look. The slug must be a function of the path and nothing else.
            Case(name: "slug unchanged when directory comes into existence", needsFreshHome: false) {
                let directory = FileManager.default.temporaryDirectory
                    .appendingPathComponent("SlugStability-\(UUID().uuidString)", isDirectory: true)
                let beforeItExists = ClaudeTranscriptCodec.projectSlug(for: directory)

                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                defer { try? FileManager.default.removeItem(at: directory) }

                XCTAssertEqual(ClaudeTranscriptCodec.projectSlug(for: directory), beforeItExists)
            },
            Case(name: "resolves via the slug directory", needsFreshHome: true) {
                let written = try self.writeTranscript([#"{"type":"user","sessionId":"\#(self.sessionID)"}"#])
                let found = try self.codec.transcriptURL(
                    sessionID: self.sessionID,
                    workingDirectory: self.workingDirectory
                )
                XCTAssertEqual(found?.standardizedFileURL, written.standardizedFileURL)
            },
            // The slug mapping is ambiguous and a session's `workingDirectory` can
            // be rewritten after launch, so resolution must still succeed when the
            // directory name does not match. The filename is the session id.
            Case(name: "falls back to filename when slug does not match", needsFreshHome: true) {
                let written = try self.writeTranscript(
                    [#"{"type":"user","sessionId":"\#(self.sessionID)"}"#],
                    slug: "-somewhere-else-entirely"
                )
                let found = try self.codec.transcriptURL(
                    sessionID: self.sessionID,
                    workingDirectory: self.workingDirectory
                )
                XCTAssertEqual(found?.standardizedFileURL, written.standardizedFileURL)
            },
            Case(name: "nil when nothing matches", needsFreshHome: true) {
                try self.writeTranscript([#"{"type":"user","sessionId":"\#(self.sessionID)"}"#])
                XCTAssertNil(try self.codec.transcriptURL(
                    sessionID: UUID().uuidString,
                    workingDirectory: self.workingDirectory
                ))
            },
        ]

        for entry in cases {
            if entry.needsFreshHome {
                try? FileManager.default.removeItem(at: home)
                home = FileManager.default.temporaryDirectory
                    .appendingPathComponent("TranscriptKitTests-\(UUID().uuidString)", isDirectory: true)
                codec = ClaudeTranscriptCodec(homeDirectory: home)
            }
            try entry.run()
        }
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

    /// Synthetic / sidechain / meta-only resumes, unknown blocks, and empty
    /// sidecar-only files must not surface as human conversation — or break the
    /// reader. A subagent's parent chain would interleave two histories;
    /// system-reminders and task notifications ride a `user` role only because
    /// the API requires it; image coordinate companions and `--resume` self-nudges
    /// are CLI-injected; `isMeta` alone is legitimate (another session handing
    /// back a message); unfamiliar block types arrive between upstream releases.
    func testExclusionAndSkipPolicies() throws {
        struct Case {
            let name: String
            let lines: [String]
            let check: ([CanonicalEntry]) throws -> Void
        }

        let imageMetadata = "[Image: original 1206x2622, displayed at 920x2000. Multiply coordinates by 1.31 to map to original image.]"

        let cases: [Case] = [
            Case(
                name: "system-reminder and task-notification turns are excluded",
                lines: [
                    #"{"type":"user","timestamp":"2026-09-08T01:18:36Z","message":{"role":"user","content":"real question"}}"#,
                    #"{"type":"user","timestamp":"2026-09-08T01:18:37Z","message":{"role":"user","content":"<system-reminder>\nSome injected reminder text\n</system-reminder>"}}"#,
                    #"{"type":"user","timestamp":"2026-09-08T01:18:38Z","message":{"role":"user","content":[{"type":"text","text":"<task-notification>\n<task-id>abc</task-id>\n</task-notification>"}]}}"#
                ]
            ) { entries in
                XCTAssertEqual(entries.count, 1)
                guard case let .userMessage(text, _) = entries[0] else {
                    return XCTFail("expected a user message, got \(entries[0])")
                }
                XCTAssertEqual(text, "real question")
            },
            Case(
                name: "image-coordinate companion turn is excluded; unmarked meta is kept",
                lines: [
                    #"{"type":"user","timestamp":"2026-09-08T01:18:36Z","message":{"role":"user","content":"real question"}}"#,
                    #"{"type":"user","isMeta":true,"turnCompanion":true,"timestamp":"2026-09-08T01:18:37Z","message":{"role":"user","content":"\#(imageMetadata)"}}"#,
                    #"{"type":"user","isMeta":true,"timestamp":"2026-09-08T01:18:38Z","message":{"role":"user","content":"\#(imageMetadata)"}}"#
                ]
            ) { entries in
                XCTAssertEqual(entries.count, 2)
                guard case let .userMessage(first, _) = entries[0],
                      case let .userMessage(second, _) = entries[1] else {
                    return XCTFail("expected the real and unmarked messages, got \(entries)")
                }
                XCTAssertEqual(first, "real question")
                XCTAssertEqual(second, imageMetadata)
            },
            Case(
                name: "resume self-nudge and synthetic no-op reply are excluded",
                lines: [
                    #"{"type":"user","timestamp":"2026-09-08T01:18:36Z","message":{"role":"user","content":"real question"}}"#,
                    #"{"type":"assistant","timestamp":"2026-09-08T01:18:37Z","message":{"role":"assistant","content":"real answer"}}"#,
                    #"{"type":"user","isMeta":true,"timestamp":"2026-09-08T01:18:38Z","message":{"role":"user","content":[{"type":"text","text":"Continue from where you left off."}]}}"#,
                    #"{"type":"assistant","timestamp":"2026-09-08T01:18:38Z","message":{"role":"assistant","model":"<synthetic>","content":[{"type":"text","text":"No response requested."}]}}"#
                ]
            ) { entries in
                XCTAssertEqual(entries.count, 2)
                guard case let .userMessage(userText, _) = entries[0],
                      case let .assistantMessage(assistantText, _) = entries[1] else {
                    return XCTFail("expected the real exchange, got \(entries)")
                }
                XCTAssertEqual(userText, "real question")
                XCTAssertEqual(assistantText, "real answer")
            },
            Case(
                name: "isMeta alone does not exclude legitimate content",
                lines: [
                    #"{"type":"user","isMeta":true,"timestamp":"2026-09-08T01:18:36Z","message":{"role":"user","content":"Another Claude session sent a message: hello"}}"#
                ]
            ) { entries in
                XCTAssertEqual(entries.count, 1)
                guard case let .userMessage(text, _) = entries[0] else {
                    return XCTFail("expected a user message, got \(entries[0])")
                }
                XCTAssertEqual(text, "Another Claude session sent a message: hello")
            },
            Case(
                name: "sidechain records are excluded",
                lines: [
                    #"{"type":"user","isSidechain":false,"timestamp":"2026-09-08T01:18:36Z","message":{"role":"user","content":"main thread"}}"#,
                    #"{"type":"user","isSidechain":true,"timestamp":"2026-09-08T01:18:37Z","message":{"role":"user","content":"subagent thread"}}"#
                ]
            ) { entries in
                XCTAssertEqual(entries.count, 1)
                guard case let .userMessage(text, _) = entries[0] else {
                    return XCTFail("expected a user message, got \(entries[0])")
                }
                XCTAssertEqual(text, "main thread")
            },
            Case(
                name: "unknown block types and malformed lines are skipped, not fatal",
                lines: [
                    "not json at all",
                    #"{"type":"assistant","timestamp":"2026-09-08T01:18:40Z","message":{"role":"assistant","content":[{"type":"thinking","thinking":"hmm"},{"type":"text","text":"answer"}]}}"#,
                    ""
                ]
            ) { entries in
                XCTAssertEqual(entries.count, 1)
                guard case let .assistantMessage(text, _) = entries[0] else {
                    return XCTFail("expected an assistant message, got \(entries[0])")
                }
                XCTAssertEqual(text, "answer")
            },
            Case(
                name: "transcript without conversation is reported as such",
                lines: [
                    #"{"type":"mode","mode":"default"}"#,
                    #"{"type":"cost-state","totalCostUSD":0}"#
                ]
            ) { entries in
                XCTAssertFalse(entries.hasConversationalContent)
            },
        ]

        for entry in cases {
            let url = try writeTranscript(entry.lines)
            let entries = try codec.readNative(at: url)
            try entry.check(entries)
        }
    }

    // MARK: - Images & Screenshots

    func testToolResultWithInlineImageBlockIsReadAsInlineImage() throws {
        let onePixelPNG = "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAIAAACQd1PeAAAADElEQVR4nGP4z8AAAAMBAQDJ/pLvAAAAAElFTkSuQmCC"
        let url = try writeTranscript([
            """
            {"type":"user","timestamp":"2026-09-08T01:18:36Z","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"call_1","content":[{"type":"image","source":{"type":"base64","media_type":"image/png","data":"\(onePixelPNG)"}}]}]}}
            """
        ])

        let entries = try codec.readNative(at: url)
        XCTAssertEqual(entries.count, 2)
        guard case let .toolResult(toolUseID, output, isError, _) = entries[0] else {
            return XCTFail("expected toolResult, got \(entries[0])")
        }
        XCTAssertEqual(toolUseID, "call_1")
        XCTAssertEqual(output, "")
        XCTAssertFalse(isError)

        guard case let .image(mimeType, base64, _, _) = entries[1] else {
            return XCTFail("expected image, got \(entries[1])")
        }
        XCTAssertEqual(mimeType, "image/jpeg")
        XCTAssertFalse(base64.isEmpty)
        XCTAssertNotNil(Data(base64Encoded: base64))
    }

    func testSendUserFileDeliversInlineImageFromDisk() throws {
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        let pngPath = home.appendingPathComponent("screenshot.png")
        let onePixelData = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAIAAACQd1PeAAAADElEQVR4nGP4z8AAAAMBAQDJ/pLvAAAAAElFTkSuQmCC")!
        try onePixelData.write(to: pngPath)

        let url = try writeTranscript([
            """
            {"type":"assistant","timestamp":"2026-09-08T01:18:36Z","message":{"role":"assistant","content":[{"type":"tool_use","id":"call_send","name":"SendUserFile","input":{"files":["\(pngPath.path)"],"caption":"sheet"}}]}}
            """
        ])

        let entries = try codec.readNative(at: url)
        XCTAssertEqual(entries.count, 2)
        guard case let .toolUse(id, tool, _, _) = entries[0] else {
            return XCTFail("expected toolUse, got \(entries[0])")
        }
        XCTAssertEqual(id, "call_send")
        XCTAssertEqual(tool, "SendUserFile")

        guard case let .image(mimeType, base64, filename, _) = entries[1] else {
            return XCTFail("expected image, got \(entries[1])")
        }
        XCTAssertEqual(mimeType, "image/jpeg")
        XCTAssertFalse(base64.isEmpty)
        XCTAssertEqual(filename, "screenshot.png")
    }

    func testSendUserFileWithMissingFileIsSkippedGracefully() throws {
        let url = try writeTranscript([
            """
            {"type":"assistant","timestamp":"2026-09-08T01:18:36Z","message":{"role":"assistant","content":[{"type":"tool_use","id":"call_send","name":"SendUserFile","input":{"files":["/tmp/does-not-exist-\(UUID().uuidString).png"],"caption":"missing"}}]}}
            """
        ])

        let entries = try codec.readNative(at: url)
        XCTAssertEqual(entries.count, 1)
        guard case let .toolUse(id, tool, _, _) = entries[0] else {
            return XCTFail("expected toolUse, got \(entries[0])")
        }
        XCTAssertEqual(id, "call_send")
        XCTAssertEqual(tool, "SendUserFile")
    }

    func testSendUserFileIncludesNonImagePathsAlongsideImages() throws {
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        let pngPath = home.appendingPathComponent("screenshot.png")
        let pdfPath = home.appendingPathComponent("report.pdf")
        let onePixelData = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAIAAACQd1PeAAAADElEQVR4nGP4z8AAAAMBAQDJ/pLvAAAAAElFTkSuQmCC")!
        try onePixelData.write(to: pngPath)
        try Data("report".utf8).write(to: pdfPath)

        let url = try writeTranscript([
            """
            {"type":"assistant","timestamp":"2026-09-08T01:18:36Z","message":{"role":"assistant","content":[{"type":"tool_use","id":"call_send","name":"SendUserFile","input":{"files":["\(pngPath.path)","\(pdfPath.path)"]}}]}}
            """
        ])

        let entries = try codec.readNative(at: url)
        XCTAssertEqual(entries.count, 3)
        guard case .image = entries[1] else { return XCTFail("expected image entry") }
        guard case let .systemNote(text, _) = entries[2] else {
            return XCTFail("expected file note, got \(entries[2])")
        }
        XCTAssertEqual(text, "File attachment: \(pdfPath.path)")
    }

    func testDirectImageBlockIsDownsampled() throws {
        let onePixelPNG = "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAIAAACQd1PeAAAADElEQVR4nGP4z8AAAAMBAQDJ/pLvAAAAAElFTkSuQmCC"
        let url = try writeTranscript([
            """
            {"type":"user","timestamp":"2026-09-08T01:18:36Z","message":{"role":"user","content":[{"type":"image","source":{"type":"base64","media_type":"image/png","data":"\(onePixelPNG)"}}]}}
            """
        ])

        let entries = try codec.readNative(at: url)
        XCTAssertEqual(entries.count, 1)
        guard case let .image(mimeType, base64, _, _) = entries[0] else {
            return XCTFail("expected image, got \(entries[0])")
        }
        XCTAssertEqual(mimeType, "image/jpeg")
        XCTAssertFalse(base64.isEmpty)
    }

    func testSameScreenshotViewedThenSentIsNotDuplicated() throws {
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        let pngPath = home.appendingPathComponent("screenshot.png")
        let onePixelData = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAIAAACQd1PeAAAADElEQVR4nGP4z8AAAAMBAQDJ/pLvAAAAAElFTkSuQmCC")!
        try onePixelData.write(to: pngPath)
        let onePixelPNG = onePixelData.base64EncodedString()

        // A real Claude Code turn: the agent reads the screenshot off disk
        // (echoed back as a tool_result image block), then hands the same
        // file to the user via SendUserFile. Both downsample the identical
        // source bytes, so they should collapse into a single .image entry.
        let url = try writeTranscript([
            """
            {"type":"assistant","timestamp":"2026-09-08T01:18:36Z","message":{"role":"assistant","content":[{"type":"tool_use","id":"call_read","name":"Read","input":{"file_path":"\(pngPath.path)"}}]}}
            """,
            """
            {"type":"user","timestamp":"2026-09-08T01:18:37Z","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"call_read","content":[{"type":"image","source":{"type":"base64","media_type":"image/png","data":"\(onePixelPNG)"}}]}]}}
            """,
            """
            {"type":"assistant","timestamp":"2026-09-08T01:18:38Z","message":{"role":"assistant","content":[{"type":"tool_use","id":"call_send","name":"SendUserFile","input":{"files":["\(pngPath.path)"],"caption":"sheet"}}]}}
            """
        ])

        let entries = try codec.readNative(at: url)
        let images = entries.filter {
            if case .image = $0 { return true }
            return false
        }
        XCTAssertEqual(images.count, 1)
    }

    func testSendUserFileResolvesRelativePathAgainstRecordCwd() throws {
        let capture = home.appendingPathComponent("build/capture")
        try FileManager.default.createDirectory(at: capture, withIntermediateDirectories: true)
        let onePixelData = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAIAAACQd1PeAAAADElEQVR4nGP4z8AAAAMBAQDJ/pLvAAAAAElFTkSuQmCC")!
        try onePixelData.write(to: capture.appendingPathComponent("design-a.png"))

        let url = try writeTranscript([
            """
            {"type":"assistant","cwd":"\(home.path)","timestamp":"2026-09-08T01:18:36Z","message":{"role":"assistant","content":[{"type":"tool_use","id":"call_send","name":"SendUserFile","input":{"files":["build/capture/design-a.png"]}}]}}
            """
        ])

        let entries = try codec.readNative(at: url)
        guard entries.count == 2, case let .image(_, _, filename, _) = entries[1] else {
            return XCTFail("expected toolUse + image, got \(entries)")
        }
        XCTAssertEqual(filename, "design-a.png")
    }
}

import XCTest
import SessionKit
@testable import TranscriptKit

private final class CursorSeedBox: @unchecked Sendable {
    var seeded = false
}

final class CursorTranscriptCodecTests: XCTestCase {
    private var home: URL!
    private var workingDirectory: URL!
    private var codec: CursorTranscriptCodec!

    private let sessionID = "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee"

    override func setUpWithError() throws {
        try super.setUpWithError()
        home = FileManager.default.temporaryDirectory
            .appendingPathComponent("CursorTranscriptTests-\(UUID().uuidString)", isDirectory: true)
        workingDirectory = URL(fileURLWithPath: "/tmp/cursor-example")
        codec = CursorTranscriptCodec(homeDirectory: home)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: home)
        try super.tearDownWithError()
    }

    @discardableResult
    private func writeTranscript(_ lines: [String], slug: String? = nil) throws -> URL {
        let directory = home
            .appendingPathComponent(".cursor/projects", isDirectory: true)
            .appendingPathComponent(slug ?? CursorTranscriptCodec.projectSlugCandidates(for: workingDirectory)[0], isDirectory: true)
            .appendingPathComponent("agent-transcripts", isDirectory: true)
            .appendingPathComponent(sessionID, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = directory.appendingPathComponent("\(sessionID).jsonl")
        try lines.joined(separator: "\n").write(to: file, atomically: true, encoding: .utf8)
        return file
    }

    func testTranscriptURLResolvesViaProjectSlug() throws {
        let written = try writeTranscript([#"{"role":"user","message":{"content":[{"type":"text","text":"hi"}]}}"#])
        let found = try codec.transcriptURL(sessionID: sessionID, workingDirectory: workingDirectory)
        XCTAssertEqual(found?.standardizedFileURL, written.standardizedFileURL)
    }

    func testTranscriptURLFallsBackWhenSlugDiffers() throws {
        let written = try writeTranscript(
            [#"{"role":"user","message":{"content":[{"type":"text","text":"hi"}]}}"#],
            slug: "somewhere-else-entirely"
        )
        let found = try codec.transcriptURL(sessionID: sessionID, workingDirectory: workingDirectory)
        XCTAssertEqual(found?.standardizedFileURL, written.standardizedFileURL)
    }

    func testReadStripsUserQueryWrappersAndSkipsRedacted() throws {
        let url = try writeTranscript([
            #"{"role":"user","message":{"content":[{"type":"text","text":"<timestamp>Tue</timestamp>\n<user_query>\nHello\n</user_query>"}]}}"#,
            #"{"role":"assistant","message":{"content":[{"type":"text","text":"Hi there"},{"type":"text","text":"[REDACTED]"}]}}"#,
            #"{"role":"system","message":{"content":[{"type":"text","text":"ignored"}]}}"#,
            #"not json"#,
            #"{"role":"assistant","message":{"content":[{"type":"redacted-reasoning","data":"x"}]}}"#
        ])
        let entries = try codec.readNative(at: url)
        XCTAssertEqual(entries, [
            .userMessage(text: "Hello", timestamp: entries[0].timestamp),
            .assistantMessage(text: "Hi there", timestamp: entries[1].timestamp)
        ])
    }

    func testEmbeddedSessionIDComesFromFilename() throws {
        let url = try writeTranscript([#"{"role":"user","message":{"content":[{"type":"text","text":"x"}]}}"#])
        XCTAssertEqual(try codec.embeddedSessionID(at: url), sessionID)
    }

    func testWriteNativeCreatesJSONLAndMeta() async throws {
        let entries: [CanonicalEntry] = [
            .userMessage(text: "Remember ZEBRA", timestamp: Date(timeIntervalSince1970: 1)),
            .assistantMessage(text: "OK", timestamp: Date(timeIntervalSince1970: 2))
        ]
        let expectedID = sessionID
        let expectedCWD = workingDirectory!
        let box = CursorSeedBox()
        let writing = CursorTranscriptCodec(homeDirectory: home, seedStore: { id, cwd, written in
            XCTAssertEqual(id, expectedID)
            XCTAssertEqual(cwd, expectedCWD)
            XCTAssertEqual(written.count, 2)
            box.seeded = true
        })
        let handle = try await writing.writeNative(entries, workingDirectory: workingDirectory, sessionID: sessionID)
        XCTAssertEqual(handle.nativeSessionID, sessionID)
        XCTAssertTrue(box.seeded)

        let url = try XCTUnwrap(handle.transcriptURL)
        let reread = try writing.readNative(at: url)
        XCTAssertEqual(reread.count, 2)
        XCTAssertTrue(reread[0].isConversational)
        XCTAssertTrue(reread[1].isConversational)
        guard case .userMessage(let text, _) = reread[0] else { return XCTFail("user") }
        XCTAssertEqual(text, "Remember ZEBRA")

        let metaURL = writing.chatDirectory(sessionID: sessionID, workingDirectory: workingDirectory)
            .appendingPathComponent("meta.json")
        let meta = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: metaURL)) as? [String: Any])
        XCTAssertEqual(meta["cwd"] as? String, workingDirectory.path)
        XCTAssertEqual(meta["hasConversation"] as? Bool, true)
    }

    func testRemoveNativeStateDeletesChatAndTranscript() async throws {
        let handle = try await codec.writeNative(
            [.userMessage(text: "bye", timestamp: .now)],
            workingDirectory: workingDirectory,
            sessionID: sessionID
        )
        let transcript = try XCTUnwrap(handle.transcriptURL)
        let chatDir = codec.chatDirectory(sessionID: sessionID, workingDirectory: workingDirectory)
        XCTAssertTrue(FileManager.default.fileExists(atPath: transcript.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: chatDir.path))

        try codec.removeNativeState(sessionID: sessionID, workingDirectory: workingDirectory)
        XCTAssertFalse(FileManager.default.fileExists(atPath: transcript.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: chatDir.path))
    }

    func testInvalidSessionIDIsRejected() async {
        do {
            _ = try await codec.writeNative([], workingDirectory: workingDirectory, sessionID: "not-a-uuid")
            XCTFail("expected throw")
        } catch TranscriptCodecError.invalidSessionID("not-a-uuid") {
            // expected
        } catch {
            XCTFail("unexpected \(error)")
        }
    }

    func testHandoffPromptIncludesTurns() {
        let prompt = CursorTranscriptCodec.handoffPrompt(from: [
            .userMessage(text: "token", timestamp: .now),
            .assistantMessage(text: "ack", timestamp: .now)
        ])
        XCTAssertTrue(prompt.contains("User: token"))
        XCTAssertTrue(prompt.contains("Assistant: ack"))
        XCTAssertTrue(prompt.contains("ACK"))
    }
}

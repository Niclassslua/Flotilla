import XCTest
import SessionKit
@testable import TranscriptKit

/// OpenCode is a destination only. It is written by handing a prepared export
/// file to `opencode import`, so these tests assert the file's shape and that
/// the CLI is actually invoked — the import itself is verified against the real
/// binary out of band, not from the unit suite.
final class OpenCodeTranscriptCodecTests: XCTestCase {
    private var staging: URL!
    private var imported: URLBox!

    /// Captures what would have been handed to the CLI.
    private final class URLBox: @unchecked Sendable {
        var urls: [URL] = []
        var failure: Error?
    }

    private static let epoch = Date(timeIntervalSince1970: 1_788_830_316)
    private let sessionID = "11111111-2222-3333-4444-555555555555"

    private func makeCodec() -> OpenCodeTranscriptCodec {
        let box = imported!
        return OpenCodeTranscriptCodec(stagingDirectory: staging, now: { Self.epoch }) { url in
            box.urls.append(url)
            if let failure = box.failure { throw failure }
        }
    }

    override func setUpWithError() throws {
        try super.setUpWithError()
        staging = FileManager.default.temporaryDirectory
            .appendingPathComponent("OpenCodeCodecTests-\(UUID().uuidString)", isDirectory: true)
        imported = URLBox()
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: staging)
        try super.tearDownWithError()
    }

    private func payload(at url: URL) throws -> [String: Any] {
        let data = try Data(contentsOf: url)
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    func testWritesAnExportFileAndHandsItToTheCLI() async throws {
        let codec = makeCodec()

        let handle = try await codec.writeNative(
            [.userMessage(text: "hello", timestamp: Self.epoch)],
            workingDirectory: URL(fileURLWithPath: "/tmp/example-project"),
            sessionID: sessionID
        )

        XCTAssertEqual(imported.urls.count, 1, "the session is created by OpenCode, not by us")
        XCTAssertEqual(imported.urls.first, handle.transcriptURL)
        XCTAssertTrue(handle.nativeSessionID.hasPrefix("ses_"))

        let root = try payload(at: XCTUnwrap(handle.transcriptURL))
        let info = try XCTUnwrap(root["info"] as? [String: Any])
        XCTAssertEqual(info["id"] as? String, handle.nativeSessionID)
        XCTAssertEqual(info["directory"] as? String, "/tmp/example-project")
    }

    /// User and assistant messages do not share a schema in OpenCode's format;
    /// getting this wrong makes the import fail with "Missing key".
    func testUserAndAssistantMessagesUseTheirOwnSchemas() async throws {
        let codec = makeCodec()

        let handle = try await codec.writeNative(
            [
                .userMessage(text: "do the thing", timestamp: Self.epoch),
                .assistantMessage(text: "done", timestamp: Self.epoch)
            ],
            workingDirectory: URL(fileURLWithPath: "/tmp/example-project"),
            sessionID: sessionID
        )

        let root = try payload(at: XCTUnwrap(handle.transcriptURL))
        let messages = try XCTUnwrap(root["messages"] as? [[String: Any]])
        XCTAssertEqual(messages.count, 2)

        let user = try XCTUnwrap(messages[0]["info"] as? [String: Any])
        XCTAssertEqual(user["role"] as? String, "user")
        XCTAssertNotNil(user["model"], "a user message carries the model as an object")
        XCTAssertNil(user["providerID"])

        let assistant = try XCTUnwrap(messages[1]["info"] as? [String: Any])
        XCTAssertEqual(assistant["role"] as? String, "assistant")
        XCTAssertEqual(assistant["parentID"] as? String, user["id"] as? String)
        XCTAssertNotNil(assistant["providerID"], "an assistant message carries it flat")
        XCTAssertNotNil(assistant["tokens"])

        // Every part is addressed to its message and session.
        let parts = try XCTUnwrap(messages[0]["parts"] as? [[String: Any]])
        XCTAssertEqual(parts[0]["messageID"] as? String, user["id"] as? String)
        XCTAssertEqual(parts[0]["sessionID"] as? String, handle.nativeSessionID)
        XCTAssertNotNil(parts[0]["id"])
    }

    /// OpenCode's message model is text parts, so tool activity is folded into
    /// readable text rather than dropped — the next agent still knows what ran.
    func testToolActivityIsFoldedIntoReadableText() async throws {
        let codec = makeCodec()
        let sanitized = codec.sanitize([
            .userMessage(text: "list files", timestamp: Self.epoch),
            .toolUse(id: "call_1", tool: "shell", input: Data(#"{"command":"ls"}"#.utf8), timestamp: Self.epoch),
            .toolResult(toolUseID: "call_1", output: "README.md", isError: false, timestamp: Self.epoch),
            .toolResult(toolUseID: "call_2", output: "it broke", isError: true, timestamp: Self.epoch),
            .image(mimeType: "image/png", base64: "AAAA", filename: nil, timestamp: Self.epoch)
        ])

        let handle = try await codec.writeNative(
            sanitized,
            workingDirectory: URL(fileURLWithPath: "/tmp/example-project"),
            sessionID: sessionID
        )

        let root = try payload(at: XCTUnwrap(handle.transcriptURL))
        let texts: [String] = try XCTUnwrap(root["messages"] as? [[String: Any]]).compactMap {
            ($0["parts"] as? [[String: Any]])?.first?["text"] as? String
        }

        XCTAssertEqual(texts.count, 4, "the image is dropped; everything else survives as text")
        XCTAssertTrue(texts.contains { $0.contains("[ran shell") })
        XCTAssertTrue(texts.contains { $0.contains("[tool result] README.md") })
        XCTAssertTrue(texts.contains { $0.contains("[tool failed] it broke") })
    }

    func testAFailedImportSurfacesRatherThanReportingSuccess() async throws {
        struct Refused: Error {}
        imported.failure = Refused()
        let codec = makeCodec()

        do {
            _ = try await codec.writeNative(
                [.userMessage(text: "hello", timestamp: Self.epoch)],
                workingDirectory: URL(fileURLWithPath: "/tmp/example-project"),
                sessionID: sessionID
            )
            XCTFail("expected the refused import to propagate")
        } catch {
            XCTAssertTrue(error is Refused)
        }
    }

    func testTheSameSessionAlwaysProducesTheSameOpenCodeIdentity() {
        XCTAssertEqual(
            OpenCodeTranscriptCodec.openCodeSessionID(from: sessionID),
            OpenCodeTranscriptCodec.openCodeSessionID(from: sessionID)
        )
        XCTAssertNotEqual(
            OpenCodeTranscriptCodec.openCodeSessionID(from: sessionID),
            OpenCodeTranscriptCodec.openCodeSessionID(from: UUID().uuidString)
        )
    }
}

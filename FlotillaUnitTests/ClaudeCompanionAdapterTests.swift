import XCTest
import SessionKit
import CompanionKit
import HooksKit
@testable import Flotilla

/// Payload shapes are Claude Code 2.1.291's (`MessageDisplay` captured live,
/// `StopFailure` from the hooks reference); see docs/providers/claude-code.md.
@MainActor
final class ClaudeCompanionAdapterTests: XCTestCase {
    private var support: URL!
    private var session: Session!

    override func setUpWithError() throws {
        support = FileManager.default.temporaryDirectory.appendingPathComponent("claude-adapter-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: support.appendingPathComponent("hooks"), withIntermediateDirectories: true)
        session = Session(
            title: "Claude session",
            goal: "Goal",
            agent: .claudeCode,
            projectID: nil,
            workingDirectory: URL(fileURLWithPath: "/tmp"),
            status: .working
        )
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: support)
    }

    private func makeAdapter() -> ClaudeCompanionAdapter {
        ClaudeCompanionAdapter(session: session, bridge: ClaudePermissionBridge(), support: support, screen: { _ in nil }, send: { _ in })
    }

    private func append(_ lines: [String], to file: URL) throws {
        let data = Data(lines.map { $0 + "\n" }.joined().utf8)
        if let handle = try? FileHandle(forWritingTo: file) {
            try handle.seekToEnd()
            try handle.write(contentsOf: data)
            try handle.close()
        } else {
            try data.write(to: file)
        }
    }

    private var displayFile: URL { HookConfigurationWriter.displayFilePath(for: session.id, supportDirectory: support) }
    private var eventFile: URL { HookConfigurationWriter.eventFilePath(for: session.id, supportDirectory: support) }

    private func chunk(_ message: String, _ index: Int, _ delta: String, final: Bool = false) -> String {
        #"{"hook_event_name":"MessageDisplay","message_id":"\#(message)","index":\#(index),"final":\#(final),"delta":"\#(delta)"}"#
    }

    func testStreamedChunksAssembleInIndexOrderEvenWhenTheyLandOutOfOrder() async throws {
        let adapter = makeAdapter()
        try append([chunk("m1", 1, "lo, "), chunk("m1", 0, "Hel")], to: displayFile)
        try await adapter.refresh()
        XCTAssertEqual(adapter.transcript.streamingText, "Hello, ")

        try append([chunk("m1", 2, "world")], to: displayFile)
        try await adapter.refresh()
        XCTAssertEqual(adapter.transcript.streamingText, "Hello, world")
    }

    func testFinalChunkEndsTheLiveTextAndStragglersDoNotReviveIt() async throws {
        let adapter = makeAdapter()
        try append([chunk("m1", 0, "Hel"), chunk("m1", 2, "!", final: true)], to: displayFile)
        try await adapter.refresh()
        XCTAssertNil(adapter.transcript.streamingText, "the finished message is read from the transcript instead")

        try append([chunk("m1", 1, "lo")], to: displayFile)
        try await adapter.refresh()
        XCTAssertNil(adapter.transcript.streamingText, "a late chunk of a finished message stays finished")
    }

    func testANewMessageReplacesThePreviousOnesText() async throws {
        let adapter = makeAdapter()
        try append([chunk("m1", 0, "first")], to: displayFile)
        try await adapter.refresh()
        try append([chunk("m2", 0, "second")], to: displayFile)
        try await adapter.refresh()
        XCTAssertEqual(adapter.transcript.streamingText, "second")
    }

    func testStopFailureNotesTheErrorTypeAndDetails() async throws {
        let adapter = makeAdapter()
        try append([chunk("m1", 0, "partial")], to: displayFile)
        try append([#"{"hook_event_name":"StopFailure","error":"rate_limit","error_details":"429 Too Many Requests","last_assistant_message":"API Error: Rate limit reached"}"#], to: eventFile)
        try await adapter.refresh()

        XCTAssertNil(adapter.transcript.streamingText)
        guard case let .turnFailed(message)? = adapter.transcript.events.last?.content else {
            return XCTFail("expected a failed-turn note, got \(String(describing: adapter.transcript.events.last))")
        }
        XCTAssertEqual(message, "Claude stopped (rate limit): 429 Too Many Requests")
    }

    func testFailureMessageFallsBackWhenFieldsAreMissing() {
        XCTAssertEqual(ClaudeCompanionAdapter.failureMessage(["error": "overloaded"]), "Claude stopped (overloaded).")
        XCTAssertEqual(ClaudeCompanionAdapter.failureMessage(["last_assistant_message": "API Error"]), "Claude stopped: API Error")
        XCTAssertEqual(ClaudeCompanionAdapter.failureMessage([:]), "Claude turn failed.")
    }
}

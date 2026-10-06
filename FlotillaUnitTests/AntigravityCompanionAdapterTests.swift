import XCTest
import SessionKit
import CompanionKit
import HooksKit
@testable import Flotilla

/// Payload shapes are agy's (`ask_question` captured 2026-09-11, `Stop` from
/// 1.3.0); see docs/providers/antigravity.md.
@MainActor
final class AntigravityCompanionAdapterTests: XCTestCase {
    private var support: URL!
    private var session: Session!

    override func setUpWithError() throws {
        support = FileManager.default.temporaryDirectory.appendingPathComponent("agy-adapter-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: support.appendingPathComponent("hooks"), withIntermediateDirectories: true)
        session = Session(
            title: "Antigravity session",
            goal: "Goal",
            agent: .antigravity,
            projectID: nil,
            workingDirectory: URL(fileURLWithPath: "/tmp"),
            status: .working,
            agentSessionID: "conv-1"
        )
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: support)
    }

    private var logFile: URL { support.appendingPathComponent("agy.log") }
    private var eventFile: URL { HookConfigurationWriter.eventFilePath(for: session.id, supportDirectory: support) }

    private func makeAdapter() -> AntigravityCompanionAdapter {
        AntigravityCompanionAdapter(
            session: session,
            descriptor: CompanionRuntimeDescriptor(agent: .antigravity, endpoint: logFile.path, password: nil, createdAt: .now),
            support: support,
            screen: { _ in nil },
            send: { _ in }
        )
    }

    private func write(_ lines: [String], to file: URL) throws {
        try Data(lines.map { $0 + "\n" }.joined().utf8).write(to: file)
    }

    func testMultiSelectQuestionsKeepTheirMultiSelectFlag() async throws {
        let question = #"{"event":"PreToolUse","payload":{"conversationId":"conv-1","stepIdx":7,"toolCall":{"name":"ask_question","args":{"questions":[{"question":"Which platforms?","options":["macOS","iOS"],"is_multi_select":true}]}}}}"#
        try write([question], to: eventFile)
        try write([#"I1006 tool_confirmation_manager.go:226] Surfacing ask_question at step 7"#], to: logFile)

        let adapter = makeAdapter()
        try await adapter.refresh()

        guard case let .question(steps)? = adapter.pending.first?.kind else {
            return XCTFail("expected a question card, got \(String(describing: adapter.pending.first?.kind))")
        }
        XCTAssertEqual(steps.first?.prompt, "Which platforms?")
        XCTAssertEqual(steps.first?.allowsMultiple, true)
    }

    func testStopWithAnErrorIsNotedOnceAndAnOrdinaryStopNotAtAll() async throws {
        let ordinary = #"{"event":"Stop","payload":{"conversationId":"conv-1","error":"","executionNum":0,"fullyIdle":true,"terminationReason":"NO_TOOL_CALL"}}"#
        let failed = #"{"event":"Stop","payload":{"conversationId":"conv-1","error":"quota exhausted","executionNum":1,"fullyIdle":true,"terminationReason":"ERROR"}}"#
        try write([ordinary, failed], to: eventFile)
        try write([], to: logFile)

        let adapter = makeAdapter()
        try await adapter.refresh()
        try await adapter.refresh()

        let notes = adapter.transcript.events.compactMap { event -> String? in
            if case let .turnFailed(message) = event.content { return message }
            return nil
        }
        XCTAssertEqual(notes, ["Antigravity stopped: quota exhausted"])
    }

    func testStepLimitIsAFailureWithoutAnErrorText() {
        XCTAssertEqual(
            AntigravityCompanionAdapter.failureMessage(["error": "", "terminationReason": "MAX_STEPS_EXCEEDED"]),
            "Antigravity stopped: it reached its step limit."
        )
        XCTAssertNil(AntigravityCompanionAdapter.failureMessage(["error": "", "terminationReason": "NO_TOOL_CALL"]))
    }
}

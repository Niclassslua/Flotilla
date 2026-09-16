import XCTest
import SessionKit
import CompanionKit
@testable import Flotilla

@MainActor
final class CodexCompanionAdapterTests: XCTestCase {
    private func makeAdapter() -> (CodexCompanionAdapter, RecordingRPC) {
        var session = Session(title: "Questions", goal: "Test", agent: .codexCLI, projectID: nil, workingDirectory: URL(fileURLWithPath: "/tmp/project"), status: .working)
        session.agentSessionID = "thread-1"
        let rpc = RecordingRPC()
        return (CodexCompanionAdapter(session: session, endpoint: "/tmp/unused.sock", rpc: rpc), rpc)
    }

    private func ask(_ adapter: CodexCompanionAdapter, questions: [[String: Any]] = [["title": "Which language?", "options": ["Python", "Ruby"]]]) throws -> PendingInteraction {
        adapter.receive(["method": "item/completed", "params": ["threadId": "thread-1", "item": ["type": "agentMessage", "id": "question-1", "text": "Which language?", "delivery": "async", "questions": questions]]])
        return try XCTUnwrap(adapter.pending.first)
    }

    private func started(_ adapter: CodexCompanionAdapter, id: String = "turn-1") {
        adapter.receive(["method": "turn/started", "params": ["threadId": "thread-1", "turn": ["id": id]]])
    }

    func testAsyncAnswersSendAllQuestionsAsOneUserTurnAndTrackTheNewTurn() async throws {
        let (adapter, rpc) = makeAdapter()
        let card = try ask(adapter, questions: [["title": "Language?", "options": ["Python", "Ruby"]], ["title": "Project name?"]])
        let outcome = try await adapter.answer(card.id, with: .questionAnswers([.init(stepID: "0", selected: ["Ruby"]), .init(stepID: "1", selected: [], other: " PhoneProject \n")]))
        XCTAssertEqual(outcome, .accepted)
        XCTAssertEqual(rpc.calls.map(\.method), ["turn/start"])
        XCTAssertEqual(rpc.texts, ["Language? Ruby\nProject name? PhoneProject"])
        XCTAssertEqual(rpc.calls.first?.params["threadId"] as? String, "thread-1")
        XCTAssertTrue(rpc.replies.isEmpty, "Async questions have no JSON-RPC reply channel")
        XCTAssertTrue(adapter.pending.isEmpty)
        try await adapter.sendPrompt("Continue with tests")
        XCTAssertEqual(rpc.calls.last?.method, "turn/steer")
        XCTAssertEqual(rpc.calls.last?.params["expectedTurnId"] as? String, "new-turn")
    }

    func testAsyncQuestionRemainsAnswerableAfterFailedDeliveryAndCanBeRetried() async throws {
        let (adapter, rpc) = makeAdapter()
        let card = try ask(adapter)
        rpc.handle = { _, _ in throw ProviderConnectionError.disconnected }
        do {
            _ = try await adapter.answer(card.id, with: .questionAnswers([.init(stepID: "0", selected: ["Python"])]))
            XCTFail("Expected delivery failure")
        } catch { }
        XCTAssertEqual(adapter.pending.map(\.id), [card.id])
        rpc.handle = nil
        let retried = try await adapter.answer(card.id, with: .questionAnswers([.init(stepID: "0", selected: [], other: "Swift")]))
        XCTAssertEqual(retried, .accepted)
        XCTAssertEqual(rpc.texts.last, "Swift")
    }

    func testPollingAndPhonePromptShareTheConnectionAttempt() async throws {
        let (adapter, rpc) = makeAdapter()
        let connecting = AsyncStream<Void>.makeStream()
        var release: CheckedContinuation<Void, Never>?
        rpc.onConnect = {
            await withCheckedContinuation { continuation in
                release = continuation
                connecting.continuation.yield(())
            }
        }
        let poll = Task { try await adapter.refresh() }
        for await _ in connecting.stream { break }
        let prompt = Task { try await adapter.sendPrompt("Phone prompt") }
        await Task.yield()
        release?.resume()
        try await poll.value
        try await prompt.value
        XCTAssertEqual(rpc.connectCount, 1, "A second connect would close the socket being opened by the poll")
        XCTAssertEqual(rpc.texts, ["Phone prompt"])
    }

    func testTwoPhonesCannotSendTheSameQuestionAnswerTwice() async throws {
        let (adapter, rpc) = makeAdapter()
        let card = try ask(adapter)
        let sending = AsyncStream<Void>.makeStream()
        var release: CheckedContinuation<Void, Never>?
        rpc.handle = { _, _ in
            await withCheckedContinuation { continuation in
                release = continuation
                sending.continuation.yield(())
            }
            return ["turn": ["id": "answer-turn"]]
        }
        let first = Task { try await adapter.answer(card.id, with: .questionAnswers([.init(stepID: "0", selected: ["Ruby"])])) }
        for await _ in sending.stream { break }
        do {
            _ = try await adapter.answer(card.id, with: .questionAnswers([.init(stepID: "0", selected: ["Python"])]))
            XCTFail("Concurrent answer should be refused while delivery is uncertain")
        } catch { }
        release?.resume()
        let firstOutcome = try await first.value
        XCTAssertEqual(firstOutcome, .accepted)
        XCTAssertEqual(rpc.texts, ["Ruby"])
    }

    func testReconnectKeepsTheIdentityOfTheSameOpenQuestion() async throws {
        let (adapter, rpc) = makeAdapter()
        let card = try ask(adapter)
        adapter.close()
        rpc.handle = { _, _ in ["thread": ["turns": [["id": "question-turn", "status": "completed", "items": [["type": "agentMessage", "id": "question-1", "delivery": "async", "questions": [["title": "Which language?", "options": ["Python", "Ruby"]]]]]]]]] }
        try await adapter.refresh()
        XCTAssertEqual(adapter.pending.map(\.id), [card.id], "Reconnect must not make the phone think the Mac answered")
    }

    func testAsyncAnswerSteersWorkingTurnAndStartsNewTurnIfItJustFinished() async throws {
        for rejection in [false, true] {
            let (adapter, rpc) = makeAdapter()
            started(adapter)
            let card = try ask(adapter)
            rpc.handle = { method, _ in
                if rejection && method == "turn/steer" { throw ProviderConnectionError.requestFailed(code: -32600, message: "No active turn") }
                return ["turn": ["id": "next-turn"]]
            }
            _ = try await adapter.answer(card.id, with: .questionAnswers([.init(stepID: "0", selected: ["Ruby"])]))
            XCTAssertEqual(rpc.calls.map(\.method), rejection ? ["turn/steer", "turn/start"] : ["turn/steer"])
            XCTAssertEqual(rpc.calls.first?.params["expectedTurnId"] as? String, "turn-1")
            XCTAssertTrue(adapter.pending.isEmpty)
        }
    }

    func testUncertainDeliveryDoesNotSendTheAnswerTwice() async throws {
        let (adapter, rpc) = makeAdapter()
        started(adapter)
        let card = try ask(adapter)
        rpc.handle = { _, _ in throw ProviderConnectionError.timeout }
        do {
            _ = try await adapter.answer(card.id, with: .questionAnswers([.init(stepID: "0", selected: ["Python"])]))
            XCTFail("Expected timeout")
        } catch { }
        XCTAssertEqual(rpc.calls.map(\.method), ["turn/steer"])
        XCTAssertEqual(adapter.pending.map(\.id), [card.id])
    }

    func testIncompleteOrInvalidAnswersDoNotDismissQuestionsOrSendInput() async throws {
        let (adapter, rpc) = makeAdapter()
        let card = try ask(adapter)
        for answers: [QuestionAnswer] in [[], [.init(stepID: "0", selected: [], other: " \n")], [.init(stepID: "0", selected: ["Unknown"])], [.init(stepID: "0", selected: ["Ruby", "Python"])]] {
            do { _ = try await adapter.answer(card.id, with: .questionAnswers(answers)); XCTFail("Invalid answer was accepted") } catch { }
            XCTAssertEqual(adapter.pending.map(\.id), [card.id])
        }
        XCTAssertTrue(rpc.calls.isEmpty)
    }

    func testBlockingQuestionsUseNativeAnswerIDsAndPermitFreeTextWithoutOptions() async throws {
        let (adapter, rpc) = makeAdapter()
        adapter.receive(["id": 42, "method": "item/tool/requestUserInput", "params": ["threadId": "thread-1", "turnId": "turn-1", "questions": [["id": "language", "header": "Language", "question": "Language?", "options": [["label": "Swift", "description": "Native"]]], ["id": "name", "header": "Name", "question": "Project name?", "options": NSNull(), "isOther": false]]]])
        let card = try XCTUnwrap(adapter.pending.first)
        guard case .question(let steps) = card.kind else { return XCTFail("Expected question") }
        XCTAssertEqual(steps[1].allowsFreeText, true)
        _ = try await adapter.answer(card.id, with: .questionAnswers([.init(stepID: "language", selected: ["Swift"]), .init(stepID: "name", selected: [], other: "Fleet")]))
        XCTAssertEqual(rpc.replies.first?.id as? Int, 42)
        let answers = try XCTUnwrap(rpc.replies.first?.result["answers"] as? [String: [String: [String]]])
        XCTAssertEqual(answers, ["language": ["answers": ["Swift"]], "name": ["answers": ["Fleet"]]])
        XCTAssertTrue(rpc.calls.isEmpty)
    }

    func testMacAnswerAndDuplicateNotificationsDoNotLeaveStaleCards() async throws {
        let (adapter, rpc) = makeAdapter()
        let card = try ask(adapter)
        _ = try ask(adapter)
        XCTAssertEqual(adapter.pending.map(\.id), [card.id])
        started(adapter, id: "mac-turn")
        XCTAssertTrue(adapter.pending.isEmpty)
        let lateAnswer = try await adapter.answer(card.id, with: .questionAnswers([]))
        XCTAssertEqual(lateAnswer, .alreadyAnswered)
        XCTAssertTrue(rpc.calls.isEmpty)
    }

    func testReconnectRestoresLatestQuestionButDoesNotResurrectOlderQuestions() async throws {
        for hasNewerTurn in [false, true] {
            let (adapter, rpc) = makeAdapter()
            let item: [String: Any] = ["type": "agentMessage", "id": "restored", "text": "Language?", "delivery": "async", "questions": [["title": "Language?", "options": ["Swift"]]]]
            var turns: [[String: Any]] = [["id": "question-turn", "status": "completed", "items": [item]]]
            if hasNewerTurn { turns.append(["id": "answer-turn", "status": "completed", "items": []]) }
            let snapshot = turns
            rpc.handle = { _, _ in ["model": "actual-model", "initialTurnsPage": ["data": Array(snapshot.suffix(1))]] }
            try await adapter.refresh()
            XCTAssertEqual(adapter.pending.count, hasNewerTurn ? 0 : 1)
            if !hasNewerTurn {
                let card = try XCTUnwrap(adapter.pending.first)
                _ = try await adapter.answer(card.id, with: .questionAnswers([.init(stepID: "0", selected: ["Swift"])]))
                XCTAssertEqual(rpc.calls.last?.method, "turn/start")
            }
        }
    }

    func testPlanApprovalUsesTheRunningModelAndMacTurnClearsThePlanCard() async throws {
        let (adapter, rpc) = makeAdapter()
        rpc.handle = { method, _ in method == "thread/resume" ? ["model": "actual-model", "thread": ["turns": []]] : ["turn": ["id": "implementation"]] }
        try await adapter.refresh()
        let message: [String: Any] = ["method": "item/completed", "params": ["threadId": "thread-1", "item": ["type": "plan", "text": "Create greeting.txt"]]]
        adapter.receive(message)
        let card = try XCTUnwrap(adapter.pending.first)
        _ = try await adapter.answer(card.id, with: .approvePlan(nil))
        let mode = try XCTUnwrap(rpc.calls.last?.params["collaborationMode"] as? [String: Any])
        XCTAssertEqual(mode["mode"] as? String, "default")
        XCTAssertEqual((mode["settings"] as? [String: Any])?["model"] as? String, "actual-model")
        XCTAssertTrue(adapter.pending.isEmpty)
        adapter.receive(message)
        started(adapter, id: "mac-implementation")
        XCTAssertTrue(adapter.pending.isEmpty)
    }

    func testPhonePlanAnswersDismissOnlyTheRecognizedTUIDialogBeforeStartingWork() async throws {
        let dialog = "Implement this plan?\n1. Yes, implement this plan\n3. No, stay in Plan mode\nPress enter to confirm or esc to go back"
        for promptIsOpen in [true, false] {
            let (base, rpc) = makeAdapter()
            var actions: [String] = []
            let adapter = CodexCompanionAdapter(session: base.session, endpoint: "/tmp/unused.sock", rpc: rpc, screen: { promptIsOpen ? dialog : "Codex is working" }, send: { bytes in
                XCTAssertEqual(bytes, Data([0x1B]))
                actions.append("escape")
            })
            rpc.handle = { method, _ in actions.append(method); return ["turn": ["id": "implementation"]] }
            adapter.receive(["method": "item/completed", "params": ["threadId": "thread-1", "item": ["type": "plan", "text": "Create greeting.txt"]]])
            let card = try XCTUnwrap(adapter.pending.first)
            _ = try await adapter.answer(card.id, with: .approvePlan(nil))
            XCTAssertEqual(actions, promptIsOpen ? ["escape", "turn/start"] : ["turn/start"], "Escape after starting the turn could interrupt the implementation")
        }
    }

    func testMacStartingWorkDuringPlanScreenCapturePreventsAnotherPhoneTurn() async throws {
        let (base, rpc) = makeAdapter()
        var sent: [Data] = []
        let adapter = CodexCompanionAdapter(session: base.session, endpoint: "/tmp/unused.sock", rpc: rpc, screen: {
            rpc.onMessage(["method": "turn/started", "params": ["threadId": "thread-1", "turn": ["id": "mac-implementation"]]])
            return "Implement this plan?\nYes, implement this plan\nNo, stay in Plan mode\nesc to go back"
        }, send: { sent.append($0) })
        adapter.receive(["method": "item/completed", "params": ["threadId": "thread-1", "item": ["type": "plan", "text": "Create greeting.txt"]]])
        let card = try XCTUnwrap(adapter.pending.first)
        let outcome = try await adapter.answer(card.id, with: .approvePlan(nil))
        XCTAssertEqual(outcome, .alreadyAnswered)
        XCTAssertTrue(sent.isEmpty)
        XCTAssertTrue(rpc.calls.isEmpty)
        adapter.close()
    }

    func testPermissionDecisionsNotesAndMacResolution() async throws {
        for (answer, decision, note): (InteractionAnswer, String, String?) in [(.allow, "accept", nil), (.alwaysAllow, "acceptForSession", nil), (.deny, "decline", nil), (.denyAndStop, "cancel", nil), (.allowWithNote("Run tests"), "accept", "Run tests"), (.denyWithNote("Use a safe path"), "decline", "Use a safe path")] {
            let (adapter, rpc) = makeAdapter()
            adapter.receive(["id": "approval-1", "method": "item/commandExecution/requestApproval", "params": ["threadId": "thread-1", "turnId": "turn-1", "command": "touch greeting.txt"]])
            let card = try XCTUnwrap(adapter.pending.first)
            _ = try await adapter.answer(card.id, with: answer)
            XCTAssertEqual(rpc.replies.first?.result["decision"] as? String, decision)
            XCTAssertEqual(rpc.texts, note.map { [$0] } ?? [])
            XCTAssertTrue(adapter.pending.isEmpty)
        }
        let (adapter, rpc) = makeAdapter()
        adapter.receive(["id": 123, "method": "item/fileChange/requestApproval", "params": ["threadId": "child-thread", "reason": "Edit config"]])
        let card = try XCTUnwrap(adapter.pending.first)
        XCTAssertEqual(card.subagent, "Codex subagent")
        adapter.receive(["method": "serverRequest/resolved", "params": ["threadId": "child-thread", "requestId": 123]])
        let lateAnswer = try await adapter.answer(card.id, with: .allow)
        XCTAssertEqual(lateAnswer, .alreadyAnswered)
        XCTAssertTrue(rpc.replies.isEmpty)
    }

    func testLegacyApplyPatchAndExecCommandApprovalsAreAnswerableFromThePhone() async throws {
        // The TUI's own "Would you like to make the following edits?" dialog:
        // a legacy v1 protocol request, not `item/fileChange/requestApproval`.
        for (answer, decision): (InteractionAnswer, [String: Any]) in [
            (.allow, ["decision": "approved"]),
            (.alwaysAllow, ["decision": "approved_for_session"]),
            (.deny, ["decision": ["denied": ["rejection": ""]]]),
            (.denyAndStop, ["decision": "abort"]),
            (.denyWithNote("Use a safe path"), ["decision": ["denied": ["rejection": "Use a safe path"]]]),
        ] {
            let (adapter, rpc) = makeAdapter()
            adapter.receive([
                "id": "patch-1", "method": "applyPatchApproval",
                "params": ["threadId": "thread-1", "fileChanges": ["/tmp/main.swift": ["type": "update", "unified_diff": "+EDIT"]]],
            ])
            let card = try XCTUnwrap(adapter.pending.first)
            guard case .permission(let permission) = card.kind else { return XCTFail("Expected permission") }
            XCTAssertEqual(permission.summary, "/tmp/main.swift")
            XCTAssertTrue(permission.detail?.contains("+EDIT") == true)
            _ = try await adapter.answer(card.id, with: answer)
            let reply = try XCTUnwrap(rpc.replies.first)
            if let expected = decision["decision"] as? String {
                XCTAssertEqual(reply.result["decision"] as? String, expected)
            } else if let expected = decision["decision"] as? [String: [String: String]] {
                let actual = reply.result["decision"] as? [String: [String: String]]
                XCTAssertEqual(actual, expected)
            }
            XCTAssertTrue(adapter.pending.isEmpty)
        }

        let (adapter, rpc) = makeAdapter()
        adapter.receive([
            "id": "exec-1", "method": "execCommandApproval",
            "params": ["threadId": "thread-1", "command": ["touch", "greeting.txt"]],
        ])
        let card = try XCTUnwrap(adapter.pending.first)
        guard case .permission(let permission) = card.kind else { return XCTFail("Expected permission") }
        XCTAssertEqual(permission.summary, "touch greeting.txt")
        _ = try await adapter.answer(card.id, with: .allow)
        XCTAssertEqual(rpc.replies.first?.result["decision"] as? String, "approved")
    }

    func testFileApprovalShowsTheProposedPathsAndDiffFromItsOwnThread() throws {
        let (adapter, _) = makeAdapter()
        for (thread, path, diff) in [("thread-1", "/tmp/main.swift", "+MAIN-EDIT"), ("child-thread", "/tmp/child.swift", "+CHILD-EDIT")] {
            adapter.receive(["method": "item/started", "params": ["threadId": thread, "item": ["type": "fileChange", "id": "same-item-id", "status": "inProgress", "changes": [["path": path, "diff": diff]]]]])
        }
        adapter.receive(["id": 42, "method": "item/fileChange/requestApproval", "params": ["threadId": "child-thread", "itemId": "same-item-id"]])
        let card = try XCTUnwrap(adapter.pending.first)
        guard case .permission(let permission) = card.kind else { return XCTFail("Expected permission") }
        XCTAssertEqual(permission.summary, "/tmp/child.swift")
        XCTAssertTrue(permission.detail?.contains("+CHILD-EDIT") == true)
        XCTAssertFalse(permission.detail?.contains("+MAIN-EDIT") == true)
        XCTAssertEqual(card.subagent, "Codex subagent")
    }

    func testStopRecoversAnActiveTurnAfterConnecting() async throws {
        let (adapter, rpc) = makeAdapter()
        rpc.handle = { _, _ in ["thread": ["turns": [["id": "running-turn", "status": "inProgress", "items": []]]]] }
        try await adapter.stop()
        XCTAssertEqual(rpc.calls.last?.method, "turn/interrupt")
        XCTAssertEqual(rpc.calls.last?.params["turnId"] as? String, "running-turn")
        XCTAssertTrue(adapter.transcript.isStopping)
        started(adapter, id: "new-turn")
        adapter.receive(["method": "turn/completed", "params": ["threadId": "thread-1", "turn": ["id": "running-turn"]]])
        try await adapter.sendPrompt("Continue")
        XCTAssertEqual(rpc.calls.last?.params["expectedTurnId"] as? String, "new-turn")
    }
}

@MainActor
private final class RecordingRPC: ProviderRPCServing {
    var onMessage: ([String: Any]) -> Void = { _ in }
    var onDisconnect: () -> Void = {}
    struct Call { var method: String; var params: [String: Any] }
    struct Reply { var id: Any; var result: [String: Any] }
    var calls: [Call] = []
    var replies: [Reply] = []
    var handle: (@MainActor (String, [String: Any]) async throws -> [String: Any])?
    var onConnect: (@MainActor () async -> Void)?
    var connectCount = 0
    var texts: [String] { calls.compactMap { ($0.params["input"] as? [[String: Any]])?.first?["text"] as? String } }
    func connect(socketPath: String) async throws { connectCount += 1; await onConnect?() }
    func request(_ method: String, params: [String: Any]) async throws -> [String: Any] {
        calls.append(.init(method: method, params: params))
        if let handle { return try await handle(method, params) }
        return method == "turn/start" ? ["turn": ["id": "new-turn"]] : [:]
    }
    func reply(id: Any, result: [String: Any]) throws { replies.append(.init(id: id, result: result)) }
    func close() { onDisconnect() }
}

import XCTest
import CryptoKit
import Network
import SessionKit
import TranscriptKit
import GitKit
import HooksKit
import CompanionKit
import PersistenceKit
import ProcessKit
@testable import Flotilla

@MainActor
final class PresenceMonitorTests: XCTestCase {
    func testMacActivityIdleTimeAndScreenLockControlAwayState() {
        var active = true
        var idle: TimeInterval = 0
        var time = Date(timeIntervalSince1970: 1_000)
        let monitor = PresenceMonitor(
            isAppActive: { active }, idleSeconds: { idle }, now: { time }, observeScreenLock: false
        )

        XCTAssertFalse(monitor.isAway)
        active = false
        time.addTimeInterval(2)
        XCTAssertTrue(monitor.isAway)
        active = true
        idle = 46
        time.addTimeInterval(2)
        XCTAssertTrue(monitor.isAway)
        idle = 0
        time.addTimeInterval(2)
        XCTAssertFalse(monitor.isAway)
        monitor.setScreenLockedForTesting(true)
        XCTAssertTrue(monitor.isAway)
        monitor.setScreenLockedForTesting(false)
        XCTAssertFalse(monitor.isAway)
    }
}

@MainActor
final class CompanionHostPairingTests: XCTestCase {
    func testOneTimeCodePairsPhoneWithoutMacApprovalAndShowsReceipt() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("companion-pair-test-\(UUID().uuidString)")
        let domain = "CompanionPairingTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: domain))
        defer {
            defaults.removePersistentDomain(forName: domain)
            try? FileManager.default.removeItem(at: directory)
        }
        let storage = CompanionHostStorage(directory: directory.appendingPathComponent("identity"))
        let appStore = AppStore(
            repository: try GRDBSessionRepository(),
            gitService: MockGitService(),
            processManager: SessionProcessManager(
                locator: AppLayerExecutableLocator(executable: URL(fileURLWithPath: "/usr/bin/env")),
                processFactory: RecordingProcessFactory()
            ),
            worktreeBaseDirectoryProvider: { directory }
        )
        let host = CompanionHost(
            store: appStore,
            gitService: MockGitService(),
            supportDirectory: directory,
            storage: storage,
            defaults: defaults
        )
        defer { host.shutdown() }

        host.isEnabled = true
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline {
            if case .listening = host.status { break }
            try await Task.sleep(for: .milliseconds(25))
        }
        guard case let .listening(port) = host.status else {
            return XCTFail("The Mac must listen before a phone can pair")
        }
        host.beginPairing()
        let payload = try XCTUnwrap(host.pairing?.payload)
        let phone = CompanionIdentity()
        let connection = try await CompanionClient.connect(
            to: [ConnectTarget(path: .lan, label: "loopback", endpoint: .hostPort(host: "127.0.0.1", port: .init(rawValue: port)!))],
            hello: {
                try Handshake.makeClientHello(
                    mode: .pair, macID: payload.macID, deviceID: "phone-1",
                    deviceName: "Niclassslua’s iPhone", identity: phone, pairingSecret: payload.secret
                )
            },
            pinnedMacKey: payload.macKey
        )
        defer { connection.session.close() }

        let attachedDeadline = Date().addingTimeInterval(5)
        while host.recentlyPairedDevice == nil, Date() < attachedDeadline {
            try await Task.sleep(for: .milliseconds(25))
        }
        XCTAssertEqual(host.recentlyPairedDevice?.name, "Niclassslua’s iPhone")
        XCTAssertEqual(host.devices.map(\.id), ["phone-1"])
        XCTAssertEqual(storage.loadDevices().map(\.id), ["phone-1"])
        XCTAssertTrue(host.connectedDeviceIDs.contains("phone-1"))
        XCTAssertNil(host.pairing, "The used code should be replaced by the success receipt")
    }
}

final class CompanionSnapshotBuilderTests: XCTestCase {
    private func session(status: SessionStatus?, reason: SessionWaitingReason? = nil, agent: AgentKind = .claudeCode) -> Session {
        Session(
            title: "Fix tests",
            goal: "Fix tests",
            agent: agent,
            projectID: nil,
            workingDirectory: URL(fileURLWithPath: "/tmp/project"),
            worktree: WorktreeInfo(branchName: "flotilla/fix", worktreePath: URL(fileURLWithPath: "/tmp/wt"), baseCheckoutPath: URL(fileURLWithPath: "/tmp/project")),
            status: status,
            waitingReason: reason
        )
    }

    private func context(answerable: [PendingInteraction] = []) -> CompanionSnapshotBuilder.SessionContext {
        .init(diffStat: GitDiffStat(files: 3, additions: 12, deletions: 4), handoffTargets: [.codexCLI], isProcessLive: true, answerable: answerable)
    }

    func testWaitingSessionWithoutABridgeRequestGetsANeedsTerminalCard() {
        let waiting = session(status: .waitingForInput, reason: .permission, agent: .codexCLI)
        let snapshot = CompanionSnapshotBuilder.snapshot(macID: "m", macName: "Studio", sessions: [waiting], projects: [], context: { _ in self.context() })

        let cards = snapshot.pending[waiting.id] ?? []
        XCTAssertEqual(cards.map(\.kind), [.needsTerminal(dialogTitle: "Permission prompt")])
        XCTAssertEqual(snapshot.sessions.first?.attentionSummary, "Needs your Mac · Permission prompt")
        // Stable across snapshots, so the phone doesn't re-animate the card.
        XCTAssertEqual(CompanionSnapshotBuilder.interactions(for: waiting, answerable: []).first?.id, cards.first?.id)
    }

    func testBridgeRequestsReplaceTheTerminalCard() {
        let waiting = session(status: .waitingForInput, reason: .permission)
        let card = PendingInteraction(kind: .permission(PermissionRequest(tool: "Bash", summary: "rm -rf build")))
        let snapshot = CompanionSnapshotBuilder.snapshot(macID: "m", macName: "Studio", sessions: [waiting], projects: [], context: { _ in self.context(answerable: [card]) })

        XCTAssertEqual(snapshot.pending[waiting.id], [card])
        XCTAssertEqual(snapshot.sessions.first?.attentionSummary, "Allow rm -rf build?")
    }

    func testAcceptedProviderAnswerDoesNotBecomeATransientNeedsTerminalCard() {
        let waiting = session(status: .waitingForInput, reason: .permission, agent: .codexCLI)
        var context = self.context()
        context.suppressTerminalFallback = true

        let snapshot = CompanionSnapshotBuilder.snapshot(macID: "m", macName: "Studio", sessions: [waiting], projects: [], context: { _ in context })

        XCTAssertNil(snapshot.pending[waiting.id], "The accepted Codex request should stay absent while the Mac status catches up")
    }

    /// OpenCode flips the session to working when one of two concurrent
    /// approvals is answered; the other is still open and must stay answerable.
    func testProviderRequestsStayVisibleWhileTheSessionReadsWorking() {
        let working = session(status: .working, agent: .openCode)
        let card = PendingInteraction(kind: .permission(PermissionRequest(tool: "external_directory", summary: "/etc/*")))
        let snapshot = CompanionSnapshotBuilder.snapshot(macID: "m", macName: "Studio", sessions: [working], projects: [], context: { _ in self.context(answerable: [card]) })

        XCTAssertEqual(snapshot.pending[working.id], [card])
        XCTAssertEqual(snapshot.sessions.first?.status, .waitingForInput)
        XCTAssertEqual(snapshot.sessions.first?.attentionSummary, "Allow /etc/*?")
    }

    func testSessionFieldsMapAcross() {
        let crashed = session(status: .crashed, agent: .openCode)
        let mapped = CompanionSnapshotBuilder.companionSession(crashed, context: context(), cards: [])

        XCTAssertEqual(mapped.branch, "flotilla/fix")
        XCTAssertTrue(mapped.hasWorktree)
        XCTAssertEqual(mapped.diffStat, DiffStat(files: 3, additions: 12, deletions: 4))
        XCTAssertEqual(mapped.crashReason, CompanionSnapshotBuilder.crashReason)
        XCTAssertTrue(mapped.hasTranscript, "OpenCode's transcript comes from its server")
        XCTAssertTrue(CompanionSnapshotBuilder.snapshot(macID: "m", macName: "S", sessions: [crashed], projects: [], context: { _ in self.context() }).pending.isEmpty)
    }

    func testCatalogOffersEveryAgent() {
        let catalog = CompanionSnapshotBuilder.catalog()
        for agent in AgentKind.allCases {
            XCTAssertFalse(catalog.entry(for: agent).models.isEmpty, "\(agent) has no models")
        }
        XCTAssertTrue(catalog.entry(for: .openCode).effortLevels.isEmpty)
    }

    func testTranscriptIDsStayStableAsItGrowsAndOldEventsAreCapped() {
        let now = Date()
        let entries = (0..<5).map { CanonicalEntry.userMessage(text: "m\($0)", timestamp: now) }
        let first = CompanionTranscriptReader.transcript(from: Array(entries.prefix(3)), limit: 10)
        let grown = CompanionTranscriptReader.transcript(from: entries, limit: 4)
        XCTAssertEqual(first.events.map(\.id), ["0", "1", "2"])
        XCTAssertEqual(grown.events.map(\.id), ["1", "2", "3", "4"])
    }

    func testAppendingNativeTranscriptKeepsEarlierEventsAndWaitsForCompleteRecord() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("companion-transcript-\(UUID().uuidString).jsonl")
        defer { try? FileManager.default.removeItem(at: url) }
        let first = #"{"type":"user","message":{"content":"first"},"timestamp":"2026-01-01T00:00:00Z"}"# + "\n"
        let second = #"{"type":"user","message":{"content":"second"},"timestamp":"2026-01-01T00:00:01Z"}"# + "\n"
        try Data(first.utf8).write(to: url)
        var sample = session(status: .working)
        sample.nativeTranscriptPath = url
        let reader = CompanionTranscriptReader(registry: .default)

        let initial = await reader.read(sample)
        XCTAssertEqual(initial.events.map(\.id), ["0:0"])

        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(second.dropLast().utf8))
        let incomplete = await reader.read(sample)
        XCTAssertEqual(incomplete.events, initial.events)
        try handle.write(contentsOf: Data("\n".utf8))
        let completed = await reader.read(sample)
        XCTAssertEqual(completed.events.map(\.id), ["0:0", "1:0"])
        if case .userMessage(let text, _)? = completed.events.last?.content {
            XCTAssertEqual(text, "second")
        } else {
            XCTFail("the appended message must become visible")
        }
    }

    func testCodexCompanionOmitsInjectedInstructionsButKeepsTheConversation() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("companion-codex-\(UUID().uuidString).jsonl")
        defer { try? FileManager.default.removeItem(at: url) }
        func record(role: String, text: String) throws -> String {
            let object: [String: Any] = [
                "type": "response_item",
                "payload": ["type": "message", "role": role,
                            "content": [["type": "input_text", "text": text]]]
            ]
            return String(decoding: try JSONSerialization.data(withJSONObject: object), as: UTF8.self) + "\n"
        }
        let initial = try [
            record(role: "developer", text: "<skills_instructions>private setup</skills_instructions>"),
            record(role: "developer", text: "<permissions_instructions>private setup</permissions_instructions>"),
            record(role: "user", text: "# AGENTS.md instructions for /project\n<INSTRUCTIONS>private rules</INSTRUCTIONS>"),
            record(role: "user", text: "<environment_context>private setup</environment_context>"),
            record(role: "user", text: "Run the tests"),
            record(role: "assistant", text: "I’ll run them now.")
        ].joined()
        try Data(initial.utf8).write(to: url)
        var sample = session(status: .working, agent: .codexCLI)
        sample.nativeTranscriptPath = url
        let reader = CompanionTranscriptReader(registry: .default)

        let opened = await reader.read(sample)
        XCTAssertEqual(opened.events.map(\.id), ["4:0", "5:0"])
        if case .userMessage(let text, _)? = opened.events.first?.content {
            XCTAssertEqual(text, "Run the tests")
        } else {
            XCTFail("the real user prompt should be visible")
        }

        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.seekToEnd()
        let appended = try [
            record(role: "developer", text: "<collaboration_mode>Default</collaboration_mode>"),
            record(role: "user", text: "Why is AGENTS.md shown in the chat?")
        ].joined()
        try handle.write(contentsOf: Data(appended.utf8))

        let updated = await reader.read(sample)
        XCTAssertEqual(updated.events.map(\.id), ["4:0", "5:0", "7:0"])
        if case .userMessage(let text, _)? = updated.events.last?.content {
            XCTAssertEqual(text, "Why is AGENTS.md shown in the chat?")
        } else {
            XCTFail("a real question about AGENTS.md should stay visible")
        }
    }

    func testOpeningLongNativeTranscriptShowsLatestWindowWithStableIDs() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("companion-long-\(UUID().uuidString).jsonl")
        defer { try? FileManager.default.removeItem(at: url) }
        let lines = (0..<600).map { index in
            #"{"type":"user","message":{"content":"message "# + String(index) + #""},"timestamp":"2026-01-01T00:00:00Z"}"#
        }.joined(separator: "\n") + "\n"
        try Data(lines.utf8).write(to: url)
        var sample = session(status: .working)
        sample.nativeTranscriptPath = url
        let reader = CompanionTranscriptReader(registry: .default)
        let opened = await reader.read(sample)
        XCTAssertEqual(opened.events.count, CompanionProtocol.transcriptEventLimit)
        XCTAssertEqual(opened.events.first?.id, "200:0")
        XCTAssertEqual(opened.events.last?.id, "599:0")
    }

    /// Cursor drops its trailing `turn_ended` record when the next turn
    /// starts, so the file grows but no longer extends what was parsed.
    /// Regression: reading on from the old offset landed inside the new user
    /// record and silently lost it.
    func testCursorTranscriptRewriteKeepsTheNextUserMessage() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("companion-cursor-\(UUID().uuidString).jsonl")
        defer { try? FileManager.default.removeItem(at: url) }
        func record(_ role: String, _ text: String) -> String {
            #"{"role":""# + role + #"","message":{"content":[{"type":"text","text":""# + text + #""}]}}"# + "\n"
        }
        let turnEnded = #"{"type":"turn_ended","status":"success"}"# + "\n"
        let firstTurn = record("user", "<user_query>\\nfirst\\n</user_query>") + record("assistant", "one")
        try Data((firstTurn + turnEnded).utf8).write(to: url)
        var sample = session(status: .working, agent: .cursorAgent)
        sample.nativeTranscriptPath = url
        let reader = CompanionTranscriptReader(registry: .default)
        _ = await reader.read(sample)

        let secondTurn = record("user", "<user_query>\\nsecond\\n</user_query>") + record("assistant", "two")
        try Data((firstTurn + secondTurn + turnEnded).utf8).write(to: url)
        let updated = await reader.read(sample)

        let users = updated.events.compactMap { event -> String? in
            if case .userMessage(let text, _) = event.content { return text }
            return nil
        }
        XCTAssertEqual(users, ["first", "second"])
        XCTAssertEqual(updated.events.map(\.id), ["0:0", "1:0", "2:0", "3:0"])
    }

    func testBlankNativeRecordDoesNotShiftIDsAfterAppend() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("companion-blank-\(UUID().uuidString).jsonl")
        defer { try? FileManager.default.removeItem(at: url) }
        let first = #"{"type":"user","message":{"content":"first"}}"# + "\n\n"
        let second = #"{"type":"user","message":{"content":"second"}}"# + "\n"
        try Data(first.utf8).write(to: url)
        var sample = session(status: .working)
        sample.nativeTranscriptPath = url
        let reader = CompanionTranscriptReader(registry: .default)

        let initial = await reader.read(sample)
        XCTAssertEqual(initial.events.map(\.id), ["0:0"])
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(second.utf8))
        let appended = await reader.read(sample)
        XCTAssertEqual(appended.events.map(\.id), ["0:0", "2:0"])
    }

    func testOpeningHugeNativeTranscriptReadsTailFastWithAccurateIDsAndAppend() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("companion-huge-\(UUID().uuidString).jsonl")
        defer { try? FileManager.default.removeItem(at: url) }
        let totalLines = 2500
        let lines = (0..<totalLines).map { index in
            #"{"type":"user","message":{"content":"message "# + String(index) + #""},"timestamp":"2026-01-01T00:00:00Z"}"#
        }.joined(separator: "\n") + "\n"
        try Data(lines.utf8).write(to: url)
        var sample = session(status: .working)
        sample.nativeTranscriptPath = url
        let reader = CompanionTranscriptReader(registry: .default)

        let opened = await reader.read(sample)
        XCTAssertEqual(opened.events.count, CompanionProtocol.transcriptEventLimit)
        XCTAssertEqual(opened.events.first?.id, "2100:0")
        XCTAssertEqual(opened.events.last?.id, "2499:0")

        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.seekToEnd()
        let newLine = #"{"type":"user","message":{"content":"message 2500"},"timestamp":"2026-01-01T00:00:02Z"}"# + "\n"
        try handle.write(contentsOf: Data(newLine.utf8))

        let updated = await reader.read(sample)
        XCTAssertEqual(updated.events.count, CompanionProtocol.transcriptEventLimit)
        XCTAssertEqual(updated.events.first?.id, "2101:0")
        XCTAssertEqual(updated.events.last?.id, "2500:0")
    }
}

final class ClaudePermissionPayloadTests: XCTestCase {
    func testCodexAllowsOnlySupportedHookDecisionFields() throws {
        let payload = #"{"flotilla_provider":"codex","request":{"tool_name":"Bash","tool_input":{"command":"touch title.json"}}}"#
        let parsed = try XCTUnwrap(ClaudePermissionPayload.parse(Data(payload.utf8)))
        for answer: InteractionAnswer in [.allow, .allowWithNote("Continue")] {
            let data = try XCTUnwrap(ClaudePermissionPayload.decision(for: answer, parsed: parsed))
            let output = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
            let specific = try XCTUnwrap(output["hookSpecificOutput"] as? [String: Any])
            XCTAssertEqual(specific["decision"] as? [String: String], ["behavior": "allow"])
        }
        for answer: InteractionAnswer in [.alwaysAllow, .denyAndStop, .approvePlan(nil), .questionAnswers([])] {
            XCTAssertNil(ClaudePermissionPayload.decision(for: answer, parsed: parsed))
        }
    }

    private func decision(_ answer: InteractionAnswer, payload: String) throws -> [String: Any] {
        let parsed = try XCTUnwrap(ClaudePermissionPayload.parse(Data(payload.utf8)))
        let data = try XCTUnwrap(ClaudePermissionPayload.decision(for: answer, parsed: parsed))
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let output = try XCTUnwrap(object["hookSpecificOutput"] as? [String: Any])
        XCTAssertEqual(output["hookEventName"] as? String, "PermissionRequest")
        return try XCTUnwrap(output["decision"] as? [String: Any])
    }

    private let bash = #"{"hook_event_name":"PermissionRequest","tool_name":"Bash","tool_input":{"command":"rm -rf build"},"agent_type":"general","permission_suggestions":[{"type":"addRules","rules":[{"toolName":"Bash","ruleContent":"rm:*"}],"behavior":"allow","destination":"session"}]}"#
    private let askQuestion = #"{"tool_name":"AskUserQuestion","tool_input":{"questions":[{"question":"Which toppings?","header":"Pizza","multiSelect":true,"options":[{"label":"Cheese"},{"label":"Basil"}]}]}}"#
    private let exitPlan = ##"{"tool_name":"ExitPlanMode","tool_input":{"plan":"# Move settings\n\n1. Add table"}}"##

    func testEnvelopeMapsToCardKind() throws {
        struct Case {
            let name: String
            let payload: String
            let check: (ClaudePermissionPayload.Parsed) throws -> Void
        }
        let cases: [Case] = [
            Case(name: "Bash→permission", payload: bash) { parsed in
                XCTAssertEqual(parsed.interaction.kind, .permission(PermissionRequest(tool: "Bash", summary: "rm -rf build", detail: "rm -rf build")))
                XCTAssertEqual(parsed.interaction.subagent, "general")
            },
            Case(name: "AskUserQuestion→question", payload: askQuestion) { parsed in
                guard case .question(let steps) = parsed.interaction.kind else { return XCTFail("expected a question") }
                XCTAssertEqual(steps.first?.allowsMultiple, true)
            },
            Case(name: "ExitPlanMode→plan", payload: exitPlan) { parsed in
                XCTAssertEqual(parsed.interaction.kind, .plan(PlanProposal(title: "Move settings", markdown: "# Move settings\n\n1. Add table")))
            },
        ]
        for entry in cases {
            let parsed = try XCTUnwrap(ClaudePermissionPayload.parse(Data(entry.payload.utf8)), entry.name)
            try entry.check(parsed)
        }
    }

    func testPermissionDecisions() throws {
        struct Case {
            let name: String
            let answer: InteractionAnswer
            let check: ([String: Any]) throws -> Void
        }
        let cases: [Case] = [
            Case(name: "allow", answer: .allow) { decision in
                XCTAssertEqual(decision["behavior"] as? String, "allow")
            },
            Case(name: "denyWithNote", answer: .denyWithNote("Use make clean")) { decision in
                XCTAssertEqual(decision["behavior"] as? String, "deny")
                XCTAssertEqual(decision["message"] as? String, "Use make clean")
            },
            Case(name: "denyAndStop", answer: .denyAndStop) { decision in
                XCTAssertEqual(decision["interrupt"] as? Bool, true)
            },
            Case(name: "alwaysAllow", answer: .alwaysAllow) { decision in
                let rules = try XCTUnwrap(decision["updatedPermissions"] as? [[String: Any]])
                XCTAssertEqual(rules.first?["destination"] as? String, "session")
                XCTAssertEqual((rules.first?["rules"] as? [[String: Any]])?.first?["ruleContent"] as? String, "rm:*")
            },
        ]
        for entry in cases {
            try entry.check(try decision(entry.answer, payload: bash))
        }
    }

    func testQuestionAnswersJoinMultiSelectAndOther() throws {
        let result = try decision(.questionAnswers([QuestionAnswer(stepID: "q0", selected: ["Cheese", "Basil"], other: "Olives")]), payload: askQuestion)
        let updated = try XCTUnwrap(result["updatedInput"] as? [String: Any])
        XCTAssertEqual((updated["answers"] as? [String: String])?["Which toppings?"], "Cheese, Basil, Olives")
        XCTAssertNotNil(updated["questions"], "the original questions must be echoed")
    }

    func testPlanApprovalSetsTheChosenMode() throws {
        let auto = try decision(.approvePlan(.autoAccept), payload: exitPlan)
        XCTAssertEqual((auto["updatedPermissions"] as? [[String: Any]])?.first?["mode"] as? String, "acceptEdits")
        let manual = try decision(.approvePlan(.askForEdits), payload: exitPlan)
        XCTAssertEqual((manual["updatedPermissions"] as? [[String: Any]])?.first?["mode"] as? String, "default")
        let revise = try decision(.revisePlan("Keep the blob"), payload: exitPlan)
        XCTAssertEqual(revise["behavior"] as? String, "deny")
    }

    func testGarbageIsIgnored() {
        XCTAssertNil(ClaudePermissionPayload.parse(Data("not json".utf8)))
        XCTAssertNil(ClaudePermissionPayload.parse(Data(#"{"tool_input":{}}"#.utf8)))
    }
}

final class CompanionFileAccessTests: XCTestCase {
    func testReadsInsideTheSessionFolderAndRefusesEscapes() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("companion-files-\(UUID().uuidString)")
        let outside = FileManager.default.temporaryDirectory.appendingPathComponent("companion-secret-\(UUID().uuidString).txt")
        try FileManager.default.createDirectory(at: root.appendingPathComponent("Sources"), withIntermediateDirectories: true)
        try "hello".write(to: root.appendingPathComponent("Sources/App.swift"), atomically: true, encoding: .utf8)
        try "secret".write(to: outside, atomically: true, encoding: .utf8)
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("link"), withDestinationURL: outside)
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: outside)
        }

        XCTAssertEqual(CompanionCommandRouter.readFile("Sources/App.swift", in: root), "hello")
        XCTAssertEqual(CompanionCommandRouter.readFile(root.appendingPathComponent("Sources/App.swift").path, in: root), "hello")
        XCTAssertNil(CompanionCommandRouter.readFile("../\(outside.lastPathComponent)", in: root))
        XCTAssertNil(CompanionCommandRouter.readFile(outside.path, in: root))
        XCTAssertNil(CompanionCommandRouter.readFile("link", in: root), "a symlink out of the folder is refused")
    }
}

final class CompanionAuthStateTests: XCTestCase {
    private final class Clock: @unchecked Sendable { var now = Date(timeIntervalSince1970: 1_000) }

    private func proof(_ secret: Data) -> (transcript: Data, proof: Data) {
        let transcript = Data("transcript".utf8)
        return (transcript, Data(HMACProof.make(secret: secret, transcript: transcript)))
    }

    func testSecretIsSingleUseAndExpires() throws {
        let clock = Clock()
        let auth = CompanionAuthState(now: { clock.now })
        let secret = Handshake.randomSecret()
        auth.beginPairing(secret: secret, expiresAt: clock.now.addingTimeInterval(300))
        let valid = proof(secret)

        XCTAssertNoThrow(try auth.verifyPairing(transcript: valid.transcript, proof: valid.proof))
        XCTAssertThrowsError(try auth.verifyPairing(transcript: valid.transcript, proof: valid.proof)) { XCTAssertEqual($0 as? RejectReason, .pairingInvalid) }

        auth.beginPairing(secret: secret, expiresAt: clock.now.addingTimeInterval(300))
        clock.now = clock.now.addingTimeInterval(301)
        XCTAssertThrowsError(try auth.verifyPairing(transcript: valid.transcript, proof: valid.proof)) { XCTAssertEqual($0 as? RejectReason, .pairingExpired) }
    }

    func testTooManyWrongGuessesBurnTheSecret() {
        let auth = CompanionAuthState()
        let secret = Handshake.randomSecret()
        auth.beginPairing(secret: secret, expiresAt: .now.addingTimeInterval(300))
        let wrong = proof(Handshake.randomSecret())
        for _ in 0..<CompanionAuthState.maximumFailedAttempts {
            XCTAssertThrowsError(try auth.verifyPairing(transcript: wrong.transcript, proof: wrong.proof))
        }
        let right = proof(secret)
        XCTAssertThrowsError(try auth.verifyPairing(transcript: right.transcript, proof: right.proof), "the right secret no longer works after five misses")
    }

    func testRevokedDevicesAreToldSo() {
        let auth = CompanionAuthState()
        let device = PairedDevice(id: "a", name: "iPhone", publicKey: Data(count: 32), pairedAt: .now)
        auth.setDevices([device], revoked: ["b"])
        XCTAssertEqual(try auth.key(for: "a"), Data(count: 32))
        XCTAssertNil(try auth.key(for: "c"))
        XCTAssertThrowsError(try auth.key(for: "b")) { XCTAssertEqual($0 as? RejectReason, .revoked) }
    }
}

private enum HMACProof {
    static func make(secret: Data, transcript: Data) -> Data {
        Data(HMAC<SHA256>.authenticationCode(for: transcript, using: SymmetricKey(data: secret)))
    }
}

/// Runs Claude's generated `PermissionRequest` hook command in a real shell.
final class CompanionBridgeHookTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        // Unix socket paths are limited to 104 bytes, so stay short.
        directory = URL(fileURLWithPath: "/tmp/fch-\(UUID().uuidString.prefix(8))", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private func permissionCommand() throws -> String {
        let arguments = HookConfigurationWriter.launchArguments(for: .claudeCode, supportDirectory: directory)
        let json = try XCTUnwrap(arguments.last)
        let settings = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
        let hooks = try XCTUnwrap(settings["hooks"] as? [String: Any])
        let group = try XCTUnwrap((hooks["PermissionRequest"] as? [[String: Any]])?.first)
        let hook = try XCTUnwrap((group["hooks"] as? [[String: Any]])?.first)
        XCTAssertEqual(hook["timeout"] as? Int, 86_400)
        return try XCTUnwrap(hook["command"] as? String)
    }

    private nonisolated static func run(_ command: String, input: String, eventFile: URL) throws -> (stdout: String, status: Int32) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", command]
        process.environment = ["FLOTILLA_HOOK_EVENT_FILE": eventFile.path, "PATH": "/usr/bin:/bin"]
        let stdin = Pipe(), stdout = Pipe()
        process.standardInput = stdin
        process.standardOutput = stdout
        try process.run()
        stdin.fileHandleForWriting.write(Data(input.utf8))
        try stdin.fileHandleForWriting.close()
        process.waitUntilExit()
        return (String(decoding: stdout.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self), process.terminationStatus)
    }

    func testWithoutTheCompanionTheHookRecordsTheEventAndStaysSilent() throws {
        let eventFile = directory.appendingPathComponent("\(UUID().uuidString).jsonl")
        let result = try Self.run(try permissionCommand(), input: #"{"tool_name":"Bash"}"#, eventFile: eventFile)
        XCTAssertEqual(result.status, 0)
        XCTAssertEqual(result.stdout, "", "no decision leaves Claude's terminal dialog in charge")
        XCTAssertEqual(try String(contentsOf: eventFile, encoding: .utf8), "{\"tool_name\":\"Bash\"}\n")
    }

    func testAStaleSocketFileFailsOpen() throws {
        let socket = HookConfigurationWriter.companionSocketPath(supportDirectory: directory)
        let bridge = ClaudeBridgeHarness()
        try bridge.listen(at: socket)
        bridge.close()
        let result = try Self.run(try permissionCommand(), input: #"{"tool_name":"Bash"}"#, eventFile: directory.appendingPathComponent("e.jsonl"))
        XCTAssertEqual(result.status, 0)
        XCTAssertEqual(result.stdout, "")
    }

    @MainActor
    func testSecondBridgeCannotReplaceLiveSocketButCanRecoverItAfterShutdown() async throws {
        let socket = HookConfigurationWriter.companionSocketPath(supportDirectory: directory)
        let first = ClaudePermissionBridge()
        let second = ClaudePermissionBridge()
        XCTAssertTrue(first.start(socketURL: socket))
        defer {
            first.stop()
            second.stop()
        }

        XCTAssertFalse(second.start(socketURL: socket), "a preview must not unlink the live app's socket")
        let sessionID = UUID()
        let command = try permissionCommand()
        let eventFile = directory.appendingPathComponent("\(sessionID.uuidString).jsonl")
        let hook = Task.detached {
            try Self.run(command, input: #"{"tool_name":"Bash","tool_input":{"command":"pwd"}}"#, eventFile: eventFile)
        }
        let deadline = Date().addingTimeInterval(5)
        while first.pending(for: sessionID).isEmpty, Date() < deadline {
            try await Task.sleep(for: .milliseconds(50))
        }
        let card = try XCTUnwrap(first.pending(for: sessionID).first)
        XCTAssertEqual(first.answer(sessionID: sessionID, interactionID: card.id, with: .allow), .accepted)
        let result = try await hook.value
        XCTAssertTrue(result.stdout.contains(#""behavior":"allow""#))

        first.stop()
        XCTAssertTrue(second.start(socketURL: socket), "a stale socket is recoverable once the owner exits")
    }

    @MainActor
    func testTheBridgeHoldsTheRequestAndReturnsThePhonesDecision() async throws {
        let sessionID = UUID()
        let eventFile = directory.appendingPathComponent("\(sessionID.uuidString).jsonl")
        let bridge = ClaudePermissionBridge()
        bridge.start(socketURL: HookConfigurationWriter.companionSocketPath(supportDirectory: directory))
        defer { bridge.stop() }

        let command = try permissionCommand()
        let hook = Task.detached {
            try Self.run(command, input: #"{"tool_name":"Bash","tool_input":{"command":"ls"}}"#, eventFile: eventFile)
        }

        let deadline = Date().addingTimeInterval(5)
        while bridge.pending(for: sessionID).isEmpty && Date() < deadline {
            try await Task.sleep(for: .milliseconds(50))
        }
        let card = try XCTUnwrap(bridge.pending(for: sessionID).first)
        XCTAssertEqual(card.kind, .permission(PermissionRequest(tool: "Bash", summary: "ls", detail: "ls")))
        XCTAssertEqual(bridge.answer(sessionID: sessionID, interactionID: card.id, with: .allow), .accepted)

        let result = try await hook.value
        XCTAssertEqual(result.status, 0)
        XCTAssertTrue(result.stdout.contains(#""behavior":"allow""#), result.stdout)
        XCTAssertEqual(bridge.answer(sessionID: sessionID, interactionID: card.id, with: .deny), .alreadyAnswered)
    }

    @MainActor
    func testCodexApprovalTravelsThroughTheGeneratedHookAndPhoneBridge() async throws {
        let sessionID = UUID()
        let eventFile = directory.appendingPathComponent("\(sessionID.uuidString).jsonl")
        XCTAssertTrue(HookConfigurationWriter().configureHooks(
            for: .codexCLI, sessionID: sessionID, workingDirectory: directory, supportDirectory: directory
        ))
        let arguments = HookConfigurationWriter.launchArguments(for: .codexCLI, supportDirectory: directory)
        let config = try XCTUnwrap(arguments.first { $0.hasPrefix("hooks.PermissionRequest=") })
        XCTAssertTrue(config.contains(" PermissionRequest"))
        XCTAssertTrue(config.contains("timeout=86400"))
        let bridge = ClaudePermissionBridge()
        bridge.start(socketURL: HookConfigurationWriter.companionSocketPath(supportDirectory: directory))
        defer { bridge.stop() }
        let script = directory.appendingPathComponent("hooks/flotilla-codex.sh")
        let payload = #"{"hook_event_name":"PermissionRequest","tool_name":"Bash","tool_input":{"command":"printf 'a\\nb'","description":"Write the session title"}}"#
        let command = "'\(script.path)' PermissionRequest"
        let hook = Task.detached { try Self.run(command, input: payload, eventFile: eventFile) }
        let deadline = Date().addingTimeInterval(5)
        while bridge.pending(for: sessionID).isEmpty && Date() < deadline {
            try await Task.sleep(for: .milliseconds(50))
        }
        let card = try XCTUnwrap(bridge.pending(for: sessionID).first)
        XCTAssertEqual(card.kind, .permission(PermissionRequest(tool: "Bash", summary: "printf 'a\\nb'", detail: "printf 'a\\nb'", allowsAlwaysAllow: false, allowsDenyAndStop: false)))
        XCTAssertEqual(bridge.answer(sessionID: sessionID, interactionID: card.id, with: .alwaysAllow), .alreadyAnswered)
        XCTAssertEqual(bridge.pending(for: sessionID).count, 1, "An unsupported decision must leave the request open")
        XCTAssertEqual(bridge.answer(sessionID: sessionID, interactionID: card.id, with: .denyWithNote("Use another path")), .accepted)
        let result = try await hook.value
        XCTAssertEqual(result.status, 0)
        let output = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(result.stdout.utf8)) as? [String: Any])
        let specific = try XCTUnwrap(output["hookSpecificOutput"] as? [String: Any])
        XCTAssertEqual(specific["hookEventName"] as? String, "PermissionRequest")
        XCTAssertEqual(specific["decision"] as? [String: String], ["behavior": "deny", "message": "Use another path"])
        XCTAssertEqual(try String(contentsOf: eventFile, encoding: .utf8), payload + "\n")
        XCTAssertEqual(bridge.answer(sessionID: sessionID, interactionID: card.id, with: .allow), .alreadyAnswered)
    }

    /// With the app-server runtime, the peer client answers approvals; a
    /// hook holding the request as well would show the phone a second card.
    @MainActor
    func testCodexApprovalUnderTheRemoteRuntimeIsLeftToThePeerClient() async throws {
        let sessionID = UUID()
        let eventFile = directory.appendingPathComponent("\(sessionID.uuidString).jsonl")
        XCTAssertTrue(HookConfigurationWriter().configureHooks(
            for: .codexCLI, sessionID: sessionID, workingDirectory: directory, supportDirectory: directory
        ))
        let bridge = ClaudePermissionBridge()
        bridge.start(socketURL: HookConfigurationWriter.companionSocketPath(supportDirectory: directory))
        defer { bridge.stop() }
        let script = directory.appendingPathComponent("hooks/flotilla-codex.sh")
        let payload = #"{"hook_event_name":"PermissionRequest","tool_name":"Bash","tool_input":{"command":"touch title.json"}}"#
        let command = "FLOTILLA_CODEX_REMOTE=1 '\(script.path)' PermissionRequest"
        let hook = Task.detached { try Self.run(command, input: payload, eventFile: eventFile) }
        let deadline = Date().addingTimeInterval(3)
        while bridge.pending(for: sessionID).isEmpty && Date() < deadline {
            try await Task.sleep(for: .milliseconds(50))
        }
        XCTAssertTrue(bridge.pending(for: sessionID).isEmpty, "the bridge must not hold a request the peer client answers")
        bridge.stop()
        let result = try await hook.value
        XCTAssertEqual(result.status, 0)
        XCTAssertEqual(result.stdout, "")
        XCTAssertEqual(try String(contentsOf: eventFile, encoding: .utf8), payload + "\n", "status tracking still sees the request")
    }

    func testCodexApprovalWithoutCompanionRemainsInTheTerminal() throws {
        XCTAssertTrue(HookConfigurationWriter().configureHooks(
            for: .codexCLI, sessionID: UUID(), workingDirectory: directory, supportDirectory: directory
        ))
        let script = directory.appendingPathComponent("hooks/flotilla-codex.sh")
        let eventFile = directory.appendingPathComponent("event.jsonl")
        let payload = #"{"hook_event_name":"PermissionRequest","tool_name":"Bash","tool_input":{"command":"touch title.json"}}"#
        let result = try Self.run("'\(script.path)' PermissionRequest", input: payload, eventFile: eventFile)
        XCTAssertEqual(result.status, 0)
        XCTAssertEqual(result.stdout, "")
        XCTAssertEqual(try String(contentsOf: eventFile, encoding: .utf8), payload + "\n")
    }

    /// A single misread from the status heuristic must not drop a request a
    /// human is still reading on their phone — only a status that reads
    /// not-waiting continuously past the grace window may retract it.
    @MainActor
    func testRetractResolvedIgnoresATransientNotWaitingReadingButActsOnceItPersists() async throws {
        let sessionID = UUID()
        let eventFile = directory.appendingPathComponent("\(sessionID.uuidString).jsonl")
        let bridge = ClaudePermissionBridge()
        bridge.start(socketURL: HookConfigurationWriter.companionSocketPath(supportDirectory: directory))
        defer { bridge.stop() }

        let command = try permissionCommand()
        let hook = Task.detached {
            try Self.run(command, input: #"{"tool_name":"Bash","tool_input":{"command":"ls"}}"#, eventFile: eventFile)
        }

        let deadline = Date().addingTimeInterval(5)
        while bridge.pending(for: sessionID).isEmpty && Date() < deadline {
            try await Task.sleep(for: .milliseconds(50))
        }
        XCTAssertFalse(bridge.pending(for: sessionID).isEmpty)

        let start = Date()
        // A single not-waiting tick, then back to waiting: the request has
        // been open long enough that the old (raise-time-based) staleness
        // check would have dropped it on this very tick.
        bridge.retractResolved(isWaiting: { _ in false }, now: start.addingTimeInterval(10))
        bridge.retractResolved(isWaiting: { _ in true }, now: start.addingTimeInterval(11))
        XCTAssertFalse(bridge.pending(for: sessionID).isEmpty, "a transient misread must not retract a still-open request")

        // Now genuinely not-waiting, continuously, past the grace window.
        bridge.retractResolved(isWaiting: { _ in false }, now: start.addingTimeInterval(20))
        bridge.retractResolved(isWaiting: { _ in false }, now: start.addingTimeInterval(24))
        XCTAssertTrue(bridge.pending(for: sessionID).isEmpty, "a durable not-waiting reading should retract the request")

        _ = try await hook.value
    }
}

/// A socket that exists and then stops accepting, like one left by a crash.
private final class ClaudeBridgeHarness {
    private var descriptor: Int32 = -1

    func listen(at url: URL) throws {
        descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        _ = withUnsafeMutableBytes(of: &address.sun_path) { buffer in
            url.path.utf8CString.withUnsafeBytes { buffer.copyMemory(from: UnsafeRawBufferPointer(rebasing: $0.prefix(buffer.count))) }
        }
        let size = socklen_t(MemoryLayout<sockaddr_un>.size)
        let bound = withUnsafePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(descriptor, $0, size) } }
        guard bound == 0 else { throw POSIXError(.EADDRINUSE) }
    }

    func close() {
        Darwin.close(descriptor)
    }
}

/// The Antigravity relay types digits into the live TUI, so it must read the
/// open dialog — never a list left in the scrollback above it.
final class AntigravityDialogRelayTests: XCTestCase {
    func testOptionsComeFromTheOpenDialogWithItsHighlightedRow() {
        // Captured from agy 1.2.2: an answered question above an open command approval.
        let screen = """
        Question 1/1: Which color do you prefer?
        > 1. Red
          2. Green
        > Run the shell command: whoami   and reply with only its output.
        Requesting permission for:
           whoami
        Run this command?
        > 1. Yes, run command
          2. Yes, and always allow in this conversation for commands that start with 'whoami'
          3. Yes, and always allow for commands that start with 'whoami' (Persist to settings.json)
          4. No, cancel
          ↑/↓ Navigate · tab Amend · ctrl+g edit/expand command
        """
        let options = AntigravityCompanionAdapter.options(in: screen)

        XCTAssertEqual(options.map(\.key), ["1", "2", "3", "4"])
        XCTAssertEqual(options.last?.label, "No, cancel")
        XCTAssertEqual(options.filter(\.isHighlighted).map(\.key), ["1"])
    }
}

/// Codex 0.154's async question tool holds no server request. Questions arrive
/// in an agent message and are answered through ordinary user input.
@MainActor
final class CodexAsyncQuestionTests: XCTestCase {
    func testAsyncQuestionIsAnswerableUntilTheNextTurnStarts() {
        let session = Session(title: "Hello", goal: "Hello", agent: .codexCLI, projectID: nil, workingDirectory: URL(fileURLWithPath: "/tmp/project"), status: .readyForReview)
        let adapter = CodexCompanionAdapter(session: session, endpoint: "/tmp/unused.sock")
        // Shape captured from a live Codex 0.154 `item/completed` notification.
        adapter.receive(["method": "item/completed", "params": [
            "threadId": "thread-1",
            "item": ["type": "agentMessage", "id": "call_1", "text": "Which language?", "delivery": "async",
                     "questions": [["title": "Which language should the hello-world script use?", "options": ["Python", "Ruby"]]]]
        ]])

        guard case .question(let steps) = adapter.pending.first?.kind else { return XCTFail("expected a question card") }
        XCTAssertEqual(steps.map(\.prompt), ["Which language should the hello-world script use?"])
        XCTAssertEqual(steps.first?.options.map(\.label), ["Python", "Ruby"])

        adapter.receive(["method": "turn/started", "params": ["threadId": "thread-1", "turn": ["id": "turn-2"]]])
        XCTAssertTrue(adapter.pending.isEmpty, "a question answered in the TUI must leave the phone")
    }
}

/// Cursor's generated flotilla-cursor.sh: it records, and never decides.
final class CursorHookTests: XCTestCase {
    private var directory: URL!
    private var worktree: URL!

    override func setUpWithError() throws {
        directory = URL(fileURLWithPath: "/tmp/fcr-\(UUID().uuidString.prefix(8))", isDirectory: true)
        worktree = directory.appendingPathComponent("wt", isDirectory: true)
        try FileManager.default.createDirectory(at: worktree, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private func installCursorHooks() throws -> URL {
        let writer = HookConfigurationWriter()
        XCTAssertTrue(writer.configureHooks(
            for: .cursorAgent,
            sessionID: UUID(),
            workingDirectory: worktree,
            supportDirectory: directory
        ))
        let script = HookConfigurationWriter.cursorWrapperScriptPath(supportDirectory: directory)
        XCTAssertTrue(FileManager.default.fileExists(atPath: script.path))
        return script
    }

    private static func run(script: URL, input: String, eventFile: URL) throws -> (stdout: String, status: Int32) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = [script.path]
        process.environment = ["FLOTILLA_HOOK_EVENT_FILE": eventFile.path, "PATH": "/usr/bin:/bin:/usr/local/bin"]
        let stdin = Pipe(), stdout = Pipe()
        process.standardInput = stdin
        process.standardOutput = stdout
        try process.run()
        stdin.fileHandleForWriting.write(Data(input.utf8))
        try stdin.fileHandleForWriting.close()
        process.waitUntilExit()
        return (String(decoding: stdout.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self), process.terminationStatus)
    }

    /// A hook `allow` doesn't skip Cursor's own approval dialog, and a held
    /// hook had nobody on the Mac to answer it — it auto-allowed after the
    /// bridge gave up, delaying every tool call by seconds.
    func testHookRecordsWithoutDecidingOrBlocking() throws {
        let script = try installCursorHooks()
        let eventFile = directory.appendingPathComponent("\(UUID().uuidString).jsonl")
        let started = Date()
        let result = try Self.run(
            script: script,
            input: #"{"hook_event_name":"preToolUse","tool_name":"Shell","tool_input":{"command":"rm -rf build"}}"#,
            eventFile: eventFile
        )
        XCTAssertLessThan(Date().timeIntervalSince(started), 2)
        XCTAssertEqual(result.status, 0)
        XCTAssertEqual(result.stdout, "")
        let recorded = try String(contentsOf: eventFile, encoding: .utf8)
        XCTAssertTrue(recorded.contains(#""hook_event_name":"preToolUse""#), recorded)
        XCTAssertTrue(recorded.contains("rm -rf build"), recorded)
    }

    func testHooksJSONHoldsNothing() throws {
        _ = try installCursorHooks()
        let data = try Data(contentsOf: worktree.appendingPathComponent(".cursor/hooks.json"))
        let root = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let hooks = try XCTUnwrap(root["hooks"] as? [String: [[String: Any]]])
        XCTAssertNotNil(hooks["preToolUse"])
        for (event, entries) in hooks {
            for entry in entries {
                XCTAssertNil(entry["failClosed"], event)
                XCTAssertEqual(entry["timeout"] as? Int, 30, event)
            }
        }
    }
}

import XCTest
import CryptoKit
import SessionKit
import TranscriptKit
import GitKit
import HooksKit
import CompanionKit
@testable import Flotilla

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
        .init(diffStat: GitDiffStat(additions: 12, deletions: 4), handoffTargets: [.codexCLI], isProcessLive: true, answerable: answerable)
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

    func testSessionFieldsMapAcross() {
        let crashed = session(status: .crashed, agent: .openCode)
        let mapped = CompanionSnapshotBuilder.companionSession(crashed, context: context(), cards: [])

        XCTAssertEqual(mapped.branch, "flotilla/fix")
        XCTAssertTrue(mapped.hasWorktree)
        XCTAssertEqual(mapped.diffStat, DiffStat(files: 0, additions: 12, deletions: 4))
        XCTAssertEqual(mapped.crashReason, CompanionSnapshotBuilder.crashReason)
        XCTAssertFalse(mapped.hasTranscript, "OpenCode has no transcript reader")
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
}

final class ClaudePermissionPayloadTests: XCTestCase {
    private func decision(_ answer: InteractionAnswer, payload: String) throws -> [String: Any] {
        let parsed = try XCTUnwrap(ClaudePermissionPayload.parse(Data(payload.utf8)))
        let data = try XCTUnwrap(ClaudePermissionPayload.decision(for: answer, parsed: parsed))
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let output = try XCTUnwrap(object["hookSpecificOutput"] as? [String: Any])
        XCTAssertEqual(output["hookEventName"] as? String, "PermissionRequest")
        return try XCTUnwrap(output["decision"] as? [String: Any])
    }

    private let bash = #"{"hook_event_name":"PermissionRequest","tool_name":"Bash","tool_input":{"command":"rm -rf build"},"agent_type":"general","permission_suggestions":[{"type":"addRules","rules":[{"toolName":"Bash","ruleContent":"rm:*"}],"behavior":"allow","destination":"session"}]}"#

    func testBashRequestBecomesAPermissionCard() throws {
        let parsed = try XCTUnwrap(ClaudePermissionPayload.parse(Data(bash.utf8)))
        XCTAssertEqual(parsed.interaction.kind, .permission(PermissionRequest(tool: "Bash", summary: "rm -rf build", detail: "rm -rf build")))
        XCTAssertEqual(parsed.interaction.subagent, "general")
    }

    func testAllowDenyAndStop() throws {
        XCTAssertEqual(try decision(.allow, payload: bash)["behavior"] as? String, "allow")
        let deny = try decision(.denyWithNote("Use make clean"), payload: bash)
        XCTAssertEqual(deny["behavior"] as? String, "deny")
        XCTAssertEqual(deny["message"] as? String, "Use make clean")
        XCTAssertEqual(try decision(.denyAndStop, payload: bash)["interrupt"] as? Bool, true)
    }

    func testAlwaysAllowEchoesClaudesOwnSuggestion() throws {
        let rules = try XCTUnwrap(try decision(.alwaysAllow, payload: bash)["updatedPermissions"] as? [[String: Any]])
        XCTAssertEqual(rules.first?["destination"] as? String, "session")
        XCTAssertEqual((rules.first?["rules"] as? [[String: Any]])?.first?["ruleContent"] as? String, "rm:*")
    }

    func testQuestionAnswersJoinMultiSelectAndOther() throws {
        let payload = #"{"tool_name":"AskUserQuestion","tool_input":{"questions":[{"question":"Which toppings?","header":"Pizza","multiSelect":true,"options":[{"label":"Cheese"},{"label":"Basil"}]}]}}"#
        let parsed = try XCTUnwrap(ClaudePermissionPayload.parse(Data(payload.utf8)))
        guard case .question(let steps) = parsed.interaction.kind else { return XCTFail("expected a question") }
        XCTAssertEqual(steps.first?.allowsMultiple, true)

        let result = try decision(.questionAnswers([QuestionAnswer(stepID: "q0", selected: ["Cheese", "Basil"], other: "Olives")]), payload: payload)
        let updated = try XCTUnwrap(result["updatedInput"] as? [String: Any])
        XCTAssertEqual((updated["answers"] as? [String: String])?["Which toppings?"], "Cheese, Basil, Olives")
        XCTAssertNotNil(updated["questions"], "the original questions must be echoed")
    }

    func testPlanApprovalSetsTheChosenMode() throws {
        let payload = ##"{"tool_name":"ExitPlanMode","tool_input":{"plan":"# Move settings\n\n1. Add table"}}"##
        let parsed = try XCTUnwrap(ClaudePermissionPayload.parse(Data(payload.utf8)))
        XCTAssertEqual(parsed.interaction.kind, .plan(PlanProposal(title: "Move settings", markdown: "# Move settings\n\n1. Add table")))

        let auto = try decision(.approvePlan(.autoAccept), payload: payload)
        XCTAssertEqual((auto["updatedPermissions"] as? [[String: Any]])?.first?["mode"] as? String, "acceptEdits")
        let manual = try decision(.approvePlan(.askForEdits), payload: payload)
        XCTAssertEqual((manual["updatedPermissions"] as? [[String: Any]])?.first?["mode"] as? String, "default")
        let revise = try decision(.revisePlan("Keep the blob"), payload: payload)
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

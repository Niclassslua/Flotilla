import XCTest
import SessionKit
import ProcessKit
@testable import TranscriptKit
@testable import Flotilla

/// Records what the process layer was asked to do, so the ordering that makes
/// a handoff work — kill the tmux session before starting a different binary —
/// can be asserted without a real PTY.
@MainActor
final class RecordingProcessStarter: SessionProcessStarting {
    enum Call: Equatable {
        case start(UUID, deliverGoal: Bool)
        case terminate(UUID)
        case killServerSide(UUID)
    }

    private(set) var calls: [Call] = []
    private(set) var startedSessions: [Session] = []
    var startError: Error?

    func startSession(_ session: Session, deliverGoal: Bool) throws {
        calls.append(.start(session.id, deliverGoal: deliverGoal))
        startedSessions.append(session)
        if let startError { throw startError }
    }

    func terminate(sessionID: UUID) { calls.append(.terminate(sessionID)) }
    func killServerSideSession(sessionID: UUID) { calls.append(.killServerSide(sessionID)) }
}

/// Stands in for a `.discoverable` agent whose id has not been pinned yet: it
/// knows nothing by session id and everything by launch time.
private struct StubDiscoveringReader: TranscriptReading {
    let agent: AgentKind = .claudeCode
    let sessionID: String
    let url: URL

    func transcriptURL(sessionID: String, workingDirectory: URL) throws -> URL? { nil }
    func embeddedSessionID(at url: URL) throws -> String? { sessionID }
    func readNative(at url: URL) throws -> [CanonicalEntry] {
        try ClaudeTranscriptCodec().readNative(at: url)
    }
    func discoverSession(workingDirectory: URL, since: Date) throws -> (sessionID: String, url: URL)? {
        (sessionID, url)
    }
}

@MainActor
final class HandoffServiceTests: XCTestCase {
    private var home: URL!
    private var workingDirectory: URL!
    private var claude: ClaudeTranscriptCodec!
    private var codex: CodexTranscriptCodec!
    private var starter: RecordingProcessStarter!
    private var service: HandoffService!

    private static let fixedDate = Date(timeIntervalSince1970: 1_788_830_316)
    private let claudeSessionID = "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee"

    override func setUpWithError() throws {
        try super.setUpWithError()
        home = FileManager.default.temporaryDirectory
            .appendingPathComponent("HandoffServiceTests-\(UUID().uuidString)", isDirectory: true)
        workingDirectory = URL(fileURLWithPath: "/tmp/example-project")
        claude = ClaudeTranscriptCodec(homeDirectory: home)
        codex = CodexTranscriptCodec(homeDirectory: home, now: { Self.fixedDate })
        starter = RecordingProcessStarter()

        let readers: [any TranscriptReading] = [claude, codex]
        let writers: [any TranscriptWriting] = [claude, codex]
        service = HandoffService(
            processManager: starter,
            registry: TranscriptCodecRegistry(readers: readers, writers: writers),
            now: { Self.fixedDate }
        )
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: home)
        try super.tearDownWithError()
    }

    @discardableResult
    private func writeClaudeTranscript(sessionID: String? = nil, conversational: Bool = true) throws -> URL {
        let id = sessionID ?? claudeSessionID
        let directory = home
            .appendingPathComponent(".claude/projects", isDirectory: true)
            .appendingPathComponent(ClaudeTranscriptCodec.projectSlug(for: workingDirectory), isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = directory.appendingPathComponent("\(id).jsonl")

        var lines = [#"{"type":"permission-mode","permissionMode":"default","sessionId":"\#(id)"}"#]
        if conversational {
            lines.append(#"{"type":"user","uuid":"u1","sessionId":"\#(id)","timestamp":"2026-09-08T01:18:36Z","message":{"role":"user","content":"list the files"}}"#)
            lines.append(#"{"type":"assistant","uuid":"a1","parentUuid":"u1","sessionId":"\#(id)","timestamp":"2026-09-08T01:18:37Z","message":{"role":"assistant","content":[{"type":"text","text":"looking"},{"type":"tool_use","id":"call_1","name":"Bash","input":{"command":"ls"}}]}}"#)
        }
        try lines.joined(separator: "\n").write(to: file, atomically: true, encoding: .utf8)
        return file
    }

    private func session(transcript: URL?) -> Session {
        Session(
            title: "Handoff",
            goal: "Goal",
            agent: .claudeCode,
            projectID: nil,
            workingDirectory: workingDirectory,
            status: .working,
            agentSessionID: claudeSessionID,
            nativeTranscriptPath: transcript,
            createdAt: Self.fixedDate,
            lastActiveAt: Self.fixedDate
        )
    }

    // MARK: - Eligibility

    func testTargetsExcludeTheCurrentAgentAndAgentsWithoutAWriter() async {
        let readers: [any TranscriptReading] = [claude, codex]
        let writers: [any TranscriptWriting] = [codex]
        let restricted = HandoffService(
            processManager: starter,
            registry: TranscriptCodecRegistry(readers: readers, writers: writers)
        )

        XCTAssertEqual(restricted.targets(for: session(transcript: nil)), [.codexCLI])
    }

    func testASessionAlreadyMidHandoffCannotStartAnother() async throws {
        var busy = session(transcript: nil)
        busy.pendingHandoff = PendingHandoff(
            sourceAgent: .claudeCode,
            sourceSessionID: claudeSessionID,
            sourceTranscriptPath: URL(fileURLWithPath: "/tmp/x.jsonl"),
            startedAt: Self.fixedDate
        )
        XCTAssertFalse(service.canHandOff(busy))
        XCTAssertTrue(service.targets(for: busy).contains(.codexCLI), "still eligible in principle")
    }

    // MARK: - Planning

    func testPlanRefusesATranscriptBelongingToAnotherSession() async throws {
        let foreign = try writeClaudeTranscript(sessionID: "99999999-9999-9999-9999-999999999999")
        var subject = session(transcript: foreign)
        subject.agentSessionID = claudeSessionID

        XCTAssertThrowsError(try service.plan(for: subject, to: .codexCLI)) { error in
            guard case .foreignSource = error as? HandoffService.HandoffError else {
                return XCTFail("expected foreignSource, got \(error)")
            }
        }
    }

    func testPlanRefusesATranscriptWithNoConversation() async throws {
        let empty = try writeClaudeTranscript(conversational: false)
        XCTAssertThrowsError(try service.plan(for: session(transcript: empty), to: .codexCLI)) { error in
            XCTAssertEqual(error as? HandoffService.HandoffError, .emptySource)
        }
    }

    func testPlanReportsWhatTheMoveWillCost() async throws {
        let source = try writeClaudeTranscript()
        let plan = try service.plan(for: session(transcript: source), to: .codexCLI)

        XCTAssertEqual(plan.target, .codexCLI)
        XCTAssertEqual(plan.sourceTranscript, source)
        // The tool call never returned, so it is given a placeholder.
        XCTAssertEqual(plan.synthesizedToolResults, 1)
        XCTAssertEqual(plan.droppedOrphanResults, 0)
        XCTAssertTrue(plan.entryCount > 0)
    }

    func testPlanningDoesNotTouchAnything() async throws {
        let source = try writeClaudeTranscript()
        _ = try service.plan(for: session(transcript: source), to: .codexCLI)

        XCTAssertTrue(starter.calls.isEmpty)
        XCTAssertTrue(FileManager.default.fileExists(atPath: source.path))
    }

    /// The reported failure: an Antigravity session that has clearly been typed
    /// into still reported "This session has not started a conversation yet",
    /// because its id is pinned by a background poll that leans on the agent's
    /// own catalog — and that catalog omits a conversation until it is titled.
    func testPlanResolvesTheSessionWhenNoNativeIDHasBeenPinnedYet() throws {
        let source = try writeClaudeTranscript()
        var unpinned = session(transcript: nil)
        unpinned.agentSessionID = nil

        // Claude's codec cannot discover, so this must still refuse...
        XCTAssertThrowsError(try service.plan(for: unpinned, to: .codexCLI)) { error in
            XCTAssertEqual(error as? HandoffService.HandoffError, .noNativeSession)
        }

        // ...but a codec that can discover resolves it, and the id it finds is
        // what the move records as the source.
        let discovering = HandoffService(
            processManager: starter,
            registry: TranscriptCodecRegistry(
                readers: [StubDiscoveringReader(sessionID: claudeSessionID, url: source)],
                writers: [codex]
            ),
            now: { Self.fixedDate }
        )
        let plan = try discovering.plan(for: unpinned, to: .codexCLI)
        XCTAssertEqual(plan.sourceSessionID, claudeSessionID)
        XCTAssertEqual(plan.sourceTranscript, source)
    }

    // MARK: - Performing

    func testPerformMovesTheSessionAndKillsTmuxBeforeStarting() async throws {
        let source = try writeClaudeTranscript()
        let subject = session(transcript: source)
        let plan = try service.plan(for: subject, to: .codexCLI)

        let moved = try await service.perform(plan)

        XCTAssertEqual(moved.agent, .codexCLI)
        XCTAssertNotEqual(moved.agentSessionID, claudeSessionID, "a fresh identity per move")
        XCTAssertNotNil(moved.nativeTranscriptPath)
        XCTAssertEqual(moved.pendingHandoff?.sourceAgent, .claudeCode)
        XCTAssertEqual(moved.pendingHandoff?.sourceSessionID, claudeSessionID)
        XCTAssertEqual(moved.pendingHandoff?.sourceTranscriptPath, source)

        // Order matters: a surviving tmux session makes the relaunch reattach
        // to the old agent instead of starting the new one.
        XCTAssertEqual(starter.calls, [
            .terminate(subject.id),
            .killServerSide(subject.id),
            .start(subject.id, deliverGoal: false)
        ])
        XCTAssertEqual(starter.startedSessions.last?.agent, .codexCLI)
    }

    /// The whole point of the probation record: until the destination proves
    /// itself, the conversation still exists in its original form.
    func testPerformLeavesTheSourceTranscriptInPlace() async throws {
        let source = try writeClaudeTranscript()
        let plan = try service.plan(for: session(transcript: source), to: .codexCLI)

        let moved = try await service.perform(plan)

        XCTAssertTrue(FileManager.default.fileExists(atPath: source.path))
        let written = try XCTUnwrap(moved.nativeTranscriptPath)
        XCTAssertTrue(FileManager.default.fileExists(atPath: written.path))
    }

    func testTheDestinationCanResumeWhatWasWritten() async throws {
        let source = try writeClaudeTranscript()
        let plan = try service.plan(for: session(transcript: source), to: .codexCLI)
        let moved = try await service.perform(plan)

        let recovered = try codex.readNative(at: XCTUnwrap(moved.nativeTranscriptPath))
        XCTAssertTrue(recovered.hasConversationalContent)
        XCTAssertEqual(
            try codex.embeddedSessionID(at: XCTUnwrap(moved.nativeTranscriptPath)),
            moved.agentSessionID
        )
    }

    /// A model names one vendor's option. `opusplan` means nothing to Codex and
    /// `gpt-6-astra` means nothing to Claude — carrying either across makes the
    /// destination refuse to start on a model it has never heard of.
    func testHandoffResetsModelAndEffortToTheDestinationsDefaults() async throws {
        let source = try writeClaudeTranscript()
        var subject = session(transcript: source)
        subject.model = "opusplan"
        subject.effort = .max

        let plan = try service.plan(for: subject, to: .codexCLI)
        let moved = try await service.perform(plan)

        XCTAssertNil(moved.model, "the destination picks its own model")
        XCTAssertNil(moved.effort)
        XCTAssertEqual(starter.startedSessions.last?.model, nil, "and launches without one")
        XCTAssertEqual(starter.startedSessions.last?.effort, nil)

        // Remembered, so a rollback can put them back.
        XCTAssertEqual(moved.pendingHandoff?.sourceModel, "opusplan")
        XCTAssertEqual(moved.pendingHandoff?.sourceEffort, .max)
    }

    func testRollbackRestoresTheModelAndEffortTheSessionWasRunning() async throws {
        let source = try writeClaudeTranscript()
        var subject = session(transcript: source)
        subject.model = "opusplan"
        subject.effort = .high

        let plan = try service.plan(for: subject, to: .codexCLI)
        let moved = try await service.perform(plan)
        let restored = try await service.rollback(moved)

        XCTAssertEqual(restored.agent, .claudeCode)
        XCTAssertEqual(restored.model, "opusplan")
        XCTAssertEqual(restored.effort, .high)
        XCTAssertEqual(starter.startedSessions.last?.model, "opusplan", "relaunched as it was")
    }

    /// A session with no override must not acquire one.
    func testASessionWithoutAModelStaysWithoutOne() async throws {
        let source = try writeClaudeTranscript()
        let plan = try service.plan(for: session(transcript: source), to: .codexCLI)
        let moved = try await service.perform(plan)

        XCTAssertNil(moved.model)
        XCTAssertNil(moved.pendingHandoff?.sourceModel)
        let restored = try await service.rollback(moved)
        XCTAssertNil(restored.model)
        XCTAssertNil(restored.effort)
    }

    // MARK: - Settling

    func testFinalizeReleasesTheSourceOnceTheDestinationHasProvedItself() async throws {
        let source = try writeClaudeTranscript()
        let plan = try service.plan(for: session(transcript: source), to: .codexCLI)
        let moved = try await service.perform(plan)

        let settled = service.finalize(moved)

        XCTAssertNil(settled.pendingHandoff)
        XCTAssertFalse(FileManager.default.fileExists(atPath: source.path), "one agent owns the conversation")
        XCTAssertEqual(settled.agent, .codexCLI)
    }

    func testRollbackReturnsTheSessionToItsSourceAgentWithHistoryIntact() async throws {
        let source = try writeClaudeTranscript()
        let plan = try service.plan(for: session(transcript: source), to: .codexCLI)
        let moved = try await service.perform(plan)
        let written = try XCTUnwrap(moved.nativeTranscriptPath)

        let restored = try await service.rollback(moved)

        XCTAssertEqual(restored.agent, .claudeCode)
        XCTAssertEqual(restored.agentSessionID, claudeSessionID)
        XCTAssertEqual(restored.nativeTranscriptPath, source)
        XCTAssertNil(restored.pendingHandoff)
        XCTAssertTrue(FileManager.default.fileExists(atPath: source.path), "never deleted, so recoverable")
        XCTAssertFalse(FileManager.default.fileExists(atPath: written.path), "the unused destination is discarded")
        XCTAssertEqual(starter.startedSessions.last?.agent, .claudeCode)
    }

    /// A destination that cannot even be launched must not leave the session
    /// stranded on an agent that does not run.
    func testADestinationThatFailsToStartIsUndoneImmediately() async throws {
        let source = try writeClaudeTranscript()
        let plan = try service.plan(for: session(transcript: source), to: .codexCLI)
        starter.startError = NSError(domain: "test", code: 1, userInfo: [NSLocalizedDescriptionKey: "no binary"])

        do {
            _ = try await service.perform(plan)
            XCTFail("expected the failed launch to surface")
        } catch {
            guard case let .targetFailedToStart(message) = error as? HandoffService.HandoffError else {
                return XCTFail("expected targetFailedToStart, got \(error)")
            }
            XCTAssertTrue(message.contains("no binary"))
        }

        XCTAssertTrue(FileManager.default.fileExists(atPath: source.path))
    }
}

import XCTest
import SessionKit
import GitKit
import ProcessKit
import PersistenceKit
import SettingsKit
@testable import TranscriptKit
@testable import Flotilla

/// Covers the seam where a handoff meets `AppStore`'s existing crash handling.
///
/// The generic resume self-heal in `handleProcessEvent` clears `agentSessionID`
/// and relaunches with a blank context. That is right for a stale resume and
/// catastrophic for a handoff — it would discard the transcript the move just
/// wrote while the source sits waiting to be cleaned up. These tests exist to
/// keep the handoff branch ahead of it.
@MainActor
final class AppStoreHandoffTests: XCTestCase {
    private var home: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        home = FileManager.default.temporaryDirectory
            .appendingPathComponent("AppStoreHandoffTests-\(UUID().uuidString)", isDirectory: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: home)
        try super.tearDownWithError()
    }

    private func manager(factory: RecordingProcessFactory) -> SessionProcessManager {
        SessionProcessManager(
            locator: AppLayerExecutableLocator(executable: URL(fileURLWithPath: "/usr/bin/env")),
            processFactory: factory,
            tmuxServerProbe: AppLayerTmuxServerProbe(usable: false)
        )
    }

    private func handoffService(processManager: SessionProcessManager) -> HandoffService {
        let claude = ClaudeTranscriptCodec(homeDirectory: home)
        let codex = CodexTranscriptCodec(homeDirectory: home)
        let readers: [any TranscriptReading] = [claude, codex]
        let writers: [any TranscriptWriting] = [claude, codex]
        return HandoffService(
            processManager: processManager,
            registry: TranscriptCodecRegistry(readers: readers, writers: writers)
        )
    }

    /// Gives the session a transcript to move, as its agent would have.
    private func seedClaudeTranscript(for session: Session) throws {
        let id = try XCTUnwrap(session.agentSessionID)
        let directory = home
            .appendingPathComponent(".claude/projects", isDirectory: true)
            .appendingPathComponent(
                ClaudeTranscriptCodec.projectSlug(for: session.workingDirectory),
                isDirectory: true
            )
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let lines = [
            #"{"type":"user","uuid":"u1","sessionId":"\#(id)","timestamp":"2026-09-08T01:18:36Z","message":{"role":"user","content":"list the files"}}"#,
            #"{"type":"assistant","uuid":"a1","parentUuid":"u1","sessionId":"\#(id)","timestamp":"2026-09-08T01:18:37Z","message":{"role":"assistant","content":[{"type":"text","text":"on it"}]}}"#
        ]
        try lines.joined(separator: "\n")
            .write(to: directory.appendingPathComponent("\(id).jsonl"), atomically: true, encoding: .utf8)
    }

    /// `SessionProcessManager` hands a process exit to the main actor through a
    /// `Task`, so the effect of firing a termination handler is not visible on
    /// the next line. Polls rather than sleeping a fixed interval so the test
    /// is neither flaky nor slower than it needs to be.
    private func waitUntil(
        _ condition: () -> Bool,
        timeout: Duration = .seconds(2),
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        let deadline = ContinuousClock.now.advanced(by: timeout)
        while ContinuousClock.now < deadline {
            if condition() { return }
            await Task.yield()
            try? await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("condition not met within \(timeout)", file: file, line: line)
    }

    private func makeStore() throws -> (AppStore, RecordingProcessFactory) {
        let factory = RecordingProcessFactory()
        let processManager = manager(factory: factory)
        let store = AppStore(
            repository: try GRDBSessionRepository(),
            gitService: MockGitService(),
            processManager: processManager,
            worktreeBaseDirectoryProvider: { URL(fileURLWithPath: "/tmp/worktrees") },
            handoffService: handoffService(processManager: processManager)
        )
        return (store, factory)
    }

    private func startedSession(in store: AppStore) async throws -> Session {
        await store.createSession(
            title: "Handoff subject",
            goal: "Move me",
            agent: .claudeCode,
            projectFolder: nil,
            checkoutMode: .mainCheckout
        )
        return try XCTUnwrap(store.sessions.first)
    }

    func testHandoffSwitchesAgentAndKeepsTheSourceUntilProbationEnds() async throws {
        let (store, _) = try makeStore()
        let session = try await startedSession(in: store)
        try seedClaudeTranscript(for: session)

        await store.handoffSession(sessionID: session.id, to: .codexCLI)

        let moved = try XCTUnwrap(store.sessions.first)
        XCTAssertNil(store.lastOperationError)
        XCTAssertEqual(moved.agent, .codexCLI)
        XCTAssertNotNil(moved.pendingHandoff, "still on probation")
        XCTAssertEqual(moved.pendingHandoff?.sourceAgent, .claudeCode)
        XCTAssertNotNil(moved.nativeTranscriptPath)

        // Persisted, so a relaunch mid-probation finds the move recorded.
        let (_, persisted) = try XCTUnwrap(store.repository.loadAll())
        XCTAssertEqual(persisted.first?.agent, .codexCLI)
    }

    /// The regression this whole branch exists to prevent.
    func testADestinationThatDiesInProbationRollsBackInsteadOfClearingTheSession() async throws {
        let (store, _) = try makeStore()
        let session = try await startedSession(in: store)
        try seedClaudeTranscript(for: session)

        await store.handoffSession(sessionID: session.id, to: .codexCLI)
        XCTAssertEqual(store.sessions.first?.agent, .codexCLI)

        // The destination exits non-zero immediately, as a missing binary would.
        let process = try XCTUnwrap(store.process(for: session.id) as? MockPTYProcess)
        process.terminationHandler?(1)
        await waitUntil { store.sessions.first?.pendingHandoff == nil }

        let restored = try XCTUnwrap(store.sessions.first)
        XCTAssertEqual(restored.agent, .claudeCode, "returned to the agent it came from")
        XCTAssertEqual(restored.agentSessionID, session.agentSessionID, "the self-heal did NOT clear the identity")
        XCTAssertNil(restored.pendingHandoff)
        XCTAssertNotEqual(restored.status, .crashed)
        XCTAssertTrue(
            store.lastOperationError?.contains("returned to") == true,
            "the user is told what happened, got: \(store.lastOperationError ?? "nil")"
        )
    }

    /// A session names itself by writing a descriptor that Flotilla waits for.
    /// When agent-managed titles are on that wait is the *only* route to a
    /// title, so anything that cancels it strands the session on its
    /// provisional name with nothing to restart it.
    ///
    /// Handing off used to cancel it — before even knowing whether the handoff
    /// would succeed, so a refused one stranded the title too.
    func testAFailedHandoffDoesNotStrandAPendingSelfReportTitle() async throws {
        /// Withholds the descriptor until the test releases it, so it can
        /// arrive strictly after the handoff attempt.
        final class Gate: @unchecked Sendable {
            var isOpen = false
        }
        let gate = Gate()

        var settings = AppSettings()
        settings.sessionDefaults.agentManagedTitleEnabled = true

        let monitor = SessionMetadataMonitor(
            dependencies: .init(
                discover: { _ in nil },
                readDescriptor: { _, _ in
                    while !gate.isOpen {
                        try? await Task.sleep(for: .milliseconds(10))
                    }
                    return AgentSelfReportDescriptor(title: "Reported title")
                }
            )
        )

        let factory = RecordingProcessFactory()
        let processManager = manager(factory: factory)
        let store = AppStore(
            repository: try GRDBSessionRepository(),
            gitService: MockGitService(),
            processManager: processManager,
            worktreeBaseDirectoryProvider: { URL(fileURLWithPath: "/tmp/worktrees") },
            settingsProvider: { settings },
            metadataMonitor: monitor,
            handoffService: handoffService(processManager: processManager)
        )

        await store.createSession(
            title: "Provisional name",
            goal: "Name yourself",
            agent: .claudeCode,
            projectFolder: nil,
            checkoutMode: .mainCheckout
        )
        let session = try XCTUnwrap(store.sessions.first)

        // No transcript was seeded, so this refuses — and must leave the
        // session, and its pending title, untouched.
        await store.handoffSession(sessionID: session.id, to: .codexCLI)
        XCTAssertNotNil(store.lastOperationError)
        XCTAssertEqual(store.sessions.first?.agent, .claudeCode)

        // The agent names itself only now.
        gate.isOpen = true
        await waitUntil { store.sessions.first?.title == "Reported title" }

        XCTAssertEqual(store.sessions.first?.title, "Reported title")
    }

    func testHandoffTargetsExcludeTheCurrentAgentAndUnwritableOnes() async throws {
        let (store, _) = try makeStore()
        let session = try await startedSession(in: store)

        let targets = store.handoffTargets(for: session)
        XCTAssertTrue(targets.contains(.codexCLI))
        XCTAssertFalse(targets.contains(.claudeCode), "moving to the agent already running it is a restart")
        XCTAssertFalse(targets.contains(.antigravity), "no writer, so never a destination")
    }

    func testHandoffWithNoTranscriptReportsWhyInsteadOfMovingTheSession() async throws {
        let (store, _) = try makeStore()
        let session = try await startedSession(in: store)
        // Deliberately no transcript seeded.

        await store.handoffSession(sessionID: session.id, to: .codexCLI)

        XCTAssertEqual(store.sessions.first?.agent, .claudeCode, "the session is untouched")
        XCTAssertNil(store.sessions.first?.pendingHandoff)
        XCTAssertNotNil(store.lastOperationError)
    }
}

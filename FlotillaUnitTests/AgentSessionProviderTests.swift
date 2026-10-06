import XCTest
import SessionKit
import AgentKit
import ProcessKit
import GitKit
import PersistenceKit
import SettingsKit
import SQLite3
@testable import ProcessKit
@testable import Flotilla

private struct TestExecutableLocator: ExecutableLocating {
    let executable: URL?

    init(executable: URL? = URL(fileURLWithPath: "/usr/bin/env")) {
        self.executable = executable
    }

    func locate(_ name: String) -> URL? {
        executable
    }
}

private struct StubCommandRunner: CommandRunning {
    let result: CommandResult
    func run(_ arguments: [String], executable: URL, workingDirectory: URL) async throws -> CommandResult { result }
    func run(_ arguments: [String], executable: URL, workingDirectory: URL, environment: [String: String]) async throws -> CommandResult { result }
}

private final class TestProcessFactory: PTYProcessCreating, @unchecked Sendable {
    func makeProcess() -> any PTYProcessProtocol {
        MockPTYProcess()
    }
}

final class AgentSessionProviderTests: XCTestCase {
    private var tempDir: URL!

    override func setUp() {
        super.setUp()
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("AgentSessionProviderTests-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tempDir)
        super.tearDown()
    }

    // MARK: - TitleSynthesizer Tests

    func testTitleSynthesizerCleansFluffAndTruncates() {
        let title1 = TitleSynthesizer.synthesize(from: "Why is the codex desktop app better than the cli? Short answer only")
        XCTAssertEqual(title1, "Why is the codex desktop app better than the cli")

        let title2 = TitleSynthesizer.synthesize(from: "Can you please fix the broken login button on the settings view?")
        XCTAssertEqual(title2, "Fix the broken login button on the settings view")

        let title3 = TitleSynthesizer.synthesize(from: "I want you to add a new git worktree feature.")
        XCTAssertEqual(title3, "Add a new git worktree feature")

        let title4 = TitleSynthesizer.synthesize(from: "Hey, hope you feel good today.")
        XCTAssertEqual(title4, "Hope you feel good today")
    }

    // MARK: - OutputBroadcaster Overflow Test

    func testOutputBroadcasterNeverOverflowsOnHeavyTraffic() async {
        let broadcaster = OutputBroadcaster()
        broadcaster.start()

        let subscription = broadcaster.subscribe()
        var receivedBytes = 0

        let consumeTask = Task {
            for await chunk in subscription {
                receivedBytes += chunk.count
                if receivedBytes >= 1_000_000 {
                    break
                }
            }
        }

        // Broadcast chunks that repeatedly exceed maxHistoryBytes
        for i in 0..<100 {
            let chunk = Data(repeating: UInt8(i % 256), count: 32 * 1024)
            broadcaster.broadcast(chunk)
        }

        broadcaster.finish()
        _ = await consumeTask.result
    }

    // MARK: - Claude Provider Tests

    func testClaudeSessionProviderParsesAiTitleAndCustomTitle() async throws {
        let claudeBase = tempDir.appendingPathComponent(".claude")
        let projectsDir = claudeBase.appendingPathComponent("projects")
        let projectFolder = projectsDir.appendingPathComponent("-Users-test-project")
        try FileManager.default.createDirectory(at: projectFolder, withIntermediateDirectories: true)

        let sessionFile = projectFolder.appendingPathComponent("test-session-1.jsonl")
        let jsonlContent = """
        {"type":"state","cwd":"/Users/test/project"}
        {"type":"ai-title","aiTitle":"Implement dark mode support","sessionId":"test-session-1"}
        """
        try jsonlContent.write(to: sessionFile, atomically: true, encoding: .utf8)

        let provider = ClaudeSessionProvider(claudeBaseURL: claudeBase)
        let session = try await provider.fetchLatestSession(for: URL(fileURLWithPath: "/Users/test/project"))

        XCTAssertNotNil(session)
        XCTAssertEqual(session?.id, "test-session-1")
        XCTAssertEqual(session?.title, "Implement dark mode support")
        XCTAssertEqual(session?.agent, .claudeCode)
        XCTAssertFalse(session?.isCustomTitle ?? true)
    }

    func testClaudeSessionProviderPrefersCustomTitleOverAiTitle() async throws {
        let claudeBase = tempDir.appendingPathComponent(".claude")
        let projectsDir = claudeBase.appendingPathComponent("projects")
        let projectFolder = projectsDir.appendingPathComponent("-Users-test-project")
        try FileManager.default.createDirectory(at: projectFolder, withIntermediateDirectories: true)

        let sessionFile = projectFolder.appendingPathComponent("test-session-2.jsonl")
        let jsonlContent = """
        {"type":"state","cwd":"/Users/test/project"}
        {"type":"ai-title","aiTitle":"Initial AI title","sessionId":"test-session-2"}
        {"type":"custom-title","customTitle":"User Renamed Session","sessionId":"test-session-2"}
        """
        try jsonlContent.write(to: sessionFile, atomically: true, encoding: .utf8)

        let provider = ClaudeSessionProvider(claudeBaseURL: claudeBase)
        let session = try await provider.fetchLatestSession(for: URL(fileURLWithPath: "/Users/test/project"))

        XCTAssertNotNil(session)
        XCTAssertEqual(session?.title, "User Renamed Session")
        XCTAssertTrue(session?.isCustomTitle ?? false)
    }

    // MARK: - Codex Provider Tests

    func testCodexSessionProviderAppendOnlyLatestTitleWins() async throws {
        let codexDir = tempDir.appendingPathComponent(".codex")
        try FileManager.default.createDirectory(at: codexDir, withIntermediateDirectories: true)
        let indexFile = codexDir.appendingPathComponent("session_index.jsonl")

        let indexContent = """
        {"id":"thread-123","thread_name":"Original Codex Goal","cwd":"/Users/test/codex-proj","updated_at":"2026-08-18T01:00:00.000Z"}
        {"id":"thread-456","thread_name":"Other Thread","cwd":"/Users/test/other","updated_at":"2026-08-18T02:00:00.000Z"}
        {"id":"thread-123","thread_name":"Renamed Codex Thread Title","cwd":"/Users/test/codex-proj","updated_at":"2026-08-18T03:00:00.000Z"}
        """
        try indexContent.write(to: indexFile, atomically: true, encoding: .utf8)

        let provider = CodexSessionProvider(
            indexURL: indexFile,
            databaseURL: codexDir.appendingPathComponent("state_5.sqlite")
        )

        let sessions = try await provider.fetchSessions()
        XCTAssertEqual(sessions.count, 2)

        let thread123 = sessions.first { $0.id == "thread-123" }
        XCTAssertNotNil(thread123)
        XCTAssertEqual(thread123?.title, "Renamed Codex Thread Title")
        XCTAssertEqual(thread123?.workingDirectory?.path, "/Users/test/codex-proj")

        let latestForProj = try await provider.fetchLatestSession(for: URL(fileURLWithPath: "/Users/test/codex-proj"))
        XCTAssertEqual(latestForProj?.title, "Renamed Codex Thread Title")
    }

    func testCodexSessionProviderIgnoresStaleSessionsBeforeSince() async throws {
        let codexDir = tempDir.appendingPathComponent(".codex")
        try FileManager.default.createDirectory(at: codexDir, withIntermediateDirectories: true)
        let indexFile = codexDir.appendingPathComponent("session_index.jsonl")

        let oldDateStr = "2026-08-10T01:00:00.000Z"
        let indexContent = """
        {"id":"thread-old","thread_name":"Old Stale Thread","cwd":"/Users/test/codex-proj","updated_at":"\(oldDateStr)"}
        """
        try indexContent.write(to: indexFile, atomically: true, encoding: .utf8)

        let provider = CodexSessionProvider(
            indexURL: indexFile,
            databaseURL: codexDir.appendingPathComponent("state_5.sqlite")
        )

        let searchSince = Date(timeIntervalSince1970: 1787000000) // Much later date
        let session = try await provider.fetchLatestSession(
            for: URL(fileURLWithPath: "/Users/test/codex-proj"),
            since: searchSince
        )

        XCTAssertNil(session, "Stale thread must not be matched when since date is in the future")
    }

    func testCodexSessionProviderSynthesizesPromptWhenNameIsNull() async throws {
        let codexDir = tempDir.appendingPathComponent(".codex")
        try FileManager.default.createDirectory(at: codexDir, withIntermediateDirectories: true)
        let dbFile = codexDir.appendingPathComponent("state_5.sqlite")

        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open(dbFile.path, &db), SQLITE_OK)
        defer { sqlite3_close(db) }

        let createTable = """
        CREATE TABLE threads (
            id text PRIMARY KEY,
            name text,
            title text NOT NULL,
            cwd text NOT NULL,
            created_at integer NOT NULL,
            created_at_ms integer NOT NULL,
            updated_at integer NOT NULL
        );
        """
        XCTAssertEqual(sqlite3_exec(db, createTable, nil, nil, nil), SQLITE_OK)

        let insertThread = """
        INSERT INTO threads (id, name, title, cwd, created_at, created_at_ms, updated_at) VALUES
        ('thread_1', NULL, '## Fix navigation split view bar\\nWe need to adjust padding', '/Users/test/codex-proj', 1787021948, 1787021948000, 1787021948);
        """
        XCTAssertEqual(sqlite3_exec(db, insertThread, nil, nil, nil), SQLITE_OK)

        let provider = CodexSessionProvider(
            indexURL: codexDir.appendingPathComponent("session_index.jsonl"),
            databaseURL: dbFile
        )

        let sessions = try await provider.fetchSessions()
        XCTAssertEqual(sessions.count, 1)
        XCTAssertEqual(sessions.first?.title, "Fix navigation split view bar")
    }

    func testCodexSessionProviderAssociatesLaunchWithFirstNewThreadInExactDirectory() async throws {
        let codexDir = tempDir.appendingPathComponent(".codex")
        try FileManager.default.createDirectory(at: codexDir, withIntermediateDirectories: true)
        let dbFile = codexDir.appendingPathComponent("state_5.sqlite")

        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open(dbFile.path, &db), SQLITE_OK)
        defer { sqlite3_close(db) }
        let createTable = """
        CREATE TABLE threads (
            id text PRIMARY KEY,
            name text,
            title text NOT NULL,
            cwd text NOT NULL,
            created_at integer NOT NULL,
            created_at_ms integer NOT NULL,
            updated_at integer NOT NULL
        );
        """
        XCTAssertEqual(sqlite3_exec(db, createTable, nil, nil, nil), SQLITE_OK)
        let insertThreads = """
        INSERT INTO threads (id, name, title, cwd, created_at, created_at_ms, updated_at) VALUES
        ('active-parent', NULL, 'An older active parent checkout thread', '/Users/test/project', 1000, 1000000, 9000),
        ('first-launch', NULL, 'First Flotilla launch', '/Users/test/project/worktree', 2000, 2000000, 3000),
        ('second-launch', NULL, 'Second Flotilla launch', '/Users/test/project/worktree', 3000, 3000000, 8000);
        """
        XCTAssertEqual(sqlite3_exec(db, insertThreads, nil, nil, nil), SQLITE_OK)

        let provider = CodexSessionProvider(
            indexURL: codexDir.appendingPathComponent("session_index.jsonl"),
            databaseURL: dbFile
        )

        let first = try await provider.fetchLatestSession(
            for: URL(fileURLWithPath: "/Users/test/project/worktree"),
            since: Date(timeIntervalSince1970: 1_500)
        )
        XCTAssertEqual(first?.id, "first-launch", "The first thread minted after a launch owns that Flotilla session.")

        let second = try await provider.fetchLatestSession(
            for: URL(fileURLWithPath: "/Users/test/project/worktree"),
            since: Date(timeIntervalSince1970: 2_500)
        )
        XCTAssertEqual(second?.id, "second-launch", "A later launch must not reuse the earlier session's ID.")

        let parent = try await provider.fetchLatestSession(
            for: URL(fileURLWithPath: "/Users/test/project/worktree"),
            since: Date(timeIntervalSince1970: 500)
        )
        XCTAssertNotEqual(parent?.id, "active-parent", "A parent checkout's active thread is not a worktree conversation.")
    }

    // MARK: - OpenCode Provider Tests

    func testOpenCodeProviderUsesItsJSONSessionList() async throws {
        let runner = StubCommandRunner(result: CommandResult(
            exitCode: 0,
            stdout: #"[{"id":"ses_live","title":"Fix the board","directory":"/Users/test/project","created":1787021948000,"updated":1787021950000}]"#,
            stderr: ""
        ))
        let provider = OpenCodeSessionProvider(
            databaseURL: tempDir.appendingPathComponent("missing.db"),
            locator: TestExecutableLocator(),
            runner: runner
        )

        let sessions = try await provider.fetchSessions()
        XCTAssertEqual(sessions.map(\.id), ["ses_live"])
        XCTAssertEqual(sessions.first?.title, "Fix the board")
        XCTAssertEqual(sessions.first?.workingDirectory?.path, "/Users/test/project")
    }

    func testOpenCodeProviderExtractsPromptWhenTitleIsDefaultPlaceholder() throws {
        let opencodeDir = tempDir.appendingPathComponent(".local/share/opencode")
        try FileManager.default.createDirectory(at: opencodeDir, withIntermediateDirectories: true)
        let dbFile = opencodeDir.appendingPathComponent("opencode.db")

        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open(dbFile.path, &db), SQLITE_OK)
        defer { sqlite3_close(db) }

        let createSessionTable = """
        CREATE TABLE session (
            id text PRIMARY KEY,
            title text NOT NULL,
            directory text NOT NULL,
            time_updated integer NOT NULL
        );
        CREATE TABLE part (
            id text PRIMARY KEY,
            session_id text NOT NULL,
            data text NOT NULL,
            time_created integer NOT NULL
        );
        """
        XCTAssertEqual(sqlite3_exec(db, createSessionTable, nil, nil, nil), SQLITE_OK)

        let insertSession = """
        INSERT INTO session (id, title, directory, time_updated) VALUES
        ('ses_1', 'New session - 2026-08-18T01:00:00Z', '/Users/test/opencode-proj', 1787021948948),
        ('ses_2', 'Custom Subagent Issue Title', '/Users/test/opencode-proj-2', 1787021950000);
        INSERT INTO part (id, session_id, data, time_created) VALUES
        ('prt_1', 'ses_1', '{"type":"text","text":"Fix the sidebar navigation width"}', 1787021949000);
        """
        XCTAssertEqual(sqlite3_exec(db, insertSession, nil, nil, nil), SQLITE_OK)

        let provider = OpenCodeSessionProvider(databaseURL: dbFile)

        let sessions = provider.fetchSessionsViaDatabase()
        XCTAssertEqual(sessions.count, 2)

        let ses1 = sessions.first { $0.id == "ses_1" }
        XCTAssertEqual(ses1?.title, "Fix the sidebar navigation width")

        let ses2 = sessions.first { $0.id == "ses_2" }
        XCTAssertEqual(ses2?.title, "Custom Subagent Issue Title")
    }

    // MARK: - Antigravity Provider Tests

    func testAntigravityProviderExtractsCheckpointObjective() async throws {
        let brainDir = tempDir.appendingPathComponent(".gemini/antigravity-cli/brain")
        let convDir = brainDir.appendingPathComponent("conv-uuid-1/.system_generated/logs")
        try FileManager.default.createDirectory(at: convDir, withIntermediateDirectories: true)

        let transcriptFile = convDir.appendingPathComponent("transcript.jsonl")
        let transcriptContent = """
        {"step_index":0,"source":"USER_EXPLICIT","type":"USER_INPUT","status":"DONE","content":"<USER_REQUEST>\\nFix login button\\n</USER_REQUEST>\\n/Users/test/antigravity-ws -> /Users/test/antigravity-ws\\n"}
        {"step_index":4,"source":"SYSTEM","type":"CHECKPOINT","status":"DONE","content":"{{ CHECKPOINT }}\\n# USER Objective:\\nFix SSO Login Button Styling\\n"}
        """
        try transcriptContent.write(to: transcriptFile, atomically: true, encoding: .utf8)

        let provider = ExperimentalAntigravitySessionProvider(brainURL: brainDir)
        let sessions = try await provider.fetchSessions()

        XCTAssertEqual(sessions.count, 1)
        XCTAssertEqual(sessions.first?.id, "conv-uuid-1")
        XCTAssertEqual(sessions.first?.title, "Fix SSO Login Button Styling")
        XCTAssertEqual(sessions.first?.workingDirectory?.path, "/Users/test/antigravity-ws")
    }

    func testAntigravityProviderRejectsMismatchingWorkspace() async throws {
        let brainDir = tempDir.appendingPathComponent(".gemini/antigravity-cli/brain")
        let convDir = brainDir.appendingPathComponent("conv-uuid-1/.system_generated/logs")
        try FileManager.default.createDirectory(at: convDir, withIntermediateDirectories: true)

        let transcriptFile = convDir.appendingPathComponent("transcript.jsonl")
        let transcriptContent = """
        {"step_index":0,"source":"USER_EXPLICIT","type":"USER_INPUT","status":"DONE","content":"<USER_REQUEST>\\nFix login button\\n</USER_REQUEST>\\n/Users/test/antigravity-ws -> /Users/test/antigravity-ws\\n"}
        {"step_index":4,"source":"SYSTEM","type":"CHECKPOINT","status":"DONE","content":"{{ CHECKPOINT }}\\n# USER Objective:\\nFix SSO Login Button Styling\\n"}
        """
        try transcriptContent.write(to: transcriptFile, atomically: true, encoding: .utf8)

        let provider = ExperimentalAntigravitySessionProvider(brainURL: brainDir)
        let session = try await provider.fetchLatestSession(for: URL(fileURLWithPath: "/Users/test/different-ws"))
        XCTAssertNil(session, "Must not return conversation from a different workspace")
    }

    func testAntigravityProviderMatchesGeneralSessionWithoutWorkspace() async throws {
        let brainDir = tempDir.appendingPathComponent(".gemini/antigravity-cli/brain")
        let convDir = brainDir.appendingPathComponent("conv-uuid-general/.system_generated/logs")
        try FileManager.default.createDirectory(at: convDir, withIntermediateDirectories: true)

        let transcriptFile = convDir.appendingPathComponent("transcript.jsonl")
        let transcriptContent = """
        {"step_index":0,"source":"USER_EXPLICIT","type":"USER_INPUT","status":"DONE","content":"<USER_REQUEST>\\nHey, what is the latest AI news?\\n</USER_REQUEST>"}
        {"step_index":3,"source":"SYSTEM","type":"CHECKPOINT","status":"DONE","content":"{{ CHECKPOINT 0 }}\\n# USER Objective:\\nRecent AI News Update\\n"}
        """
        try transcriptContent.write(to: transcriptFile, atomically: true, encoding: .utf8)

        let provider = ExperimentalAntigravitySessionProvider(brainURL: brainDir)
        let session = try await provider.fetchLatestSession(for: URL(fileURLWithPath: "/Users/test/.flotilla/general-session"))
        XCTAssertNotNil(session)
        XCTAssertEqual(session?.title, "Recent AI News Update")
    }

    func testAntigravityProviderWaitsForCheckpointWithoutFlickeringPrompt() async throws {
        let brainDir = tempDir.appendingPathComponent(".gemini/antigravity-cli/brain")
        let convDir = brainDir.appendingPathComponent("conv-uuid-fresh/.system_generated/logs")
        try FileManager.default.createDirectory(at: convDir, withIntermediateDirectories: true)

        let transcriptFile = convDir.appendingPathComponent("transcript.jsonl")
        let transcriptContent = """
        {"step_index":0,"source":"USER_EXPLICIT","type":"USER_INPUT","status":"DONE","content":"<USER_REQUEST>\\nHey, did I ask you how you feel today already?\\n</USER_REQUEST>"}
        """
        try transcriptContent.write(to: transcriptFile, atomically: true, encoding: .utf8)

        let provider = ExperimentalAntigravitySessionProvider(brainURL: brainDir)
        let sessions = try await provider.fetchSessions()
        XCTAssertTrue(sessions.isEmpty, "Should not return raw user prompt before checkpoint objective is generated")
    }

    // MARK: - AppStore Title Sync Integration Tests

    @MainActor
    func testAppStoreSyncDiscoveredTitleUpdatesSessionAndPersists() throws {
        let repo = try GRDBSessionRepository()
        let gitService = MockGitService()
        let processManager = SessionProcessManager(
            locator: TestExecutableLocator(),
            processFactory: TestProcessFactory()
        )
        let store = AppStore(
            repository: repo,
            gitService: gitService,
            processManager: processManager,
            worktreeBaseDirectoryProvider: { FileManager.default.temporaryDirectory }
        )

        let sessionID = UUID()
        let session = Session(
            id: sessionID,
            title: "Initial Heuristic Title",
            goal: "Do some task",
            agent: .claudeCode,
            projectID: nil,
            workingDirectory: FileManager.default.temporaryDirectory
        )
        try repo.save(session)
        store.reload()

        XCTAssertEqual(store.sessions.first?.title, "Initial Heuristic Title")

        // Sync new title
        store.syncDiscoveredTitle("Auto-Generated Issue Title", toSessionID: sessionID)

        XCTAssertEqual(store.sessions.first?.title, "Auto-Generated Issue Title")

        // Verify persisted to repository
        let (_, reloadedSessions) = try repo.loadAll()
        XCTAssertEqual(reloadedSessions.first?.title, "Auto-Generated Issue Title")
    }
}

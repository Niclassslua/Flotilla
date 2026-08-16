import XCTest
import SessionKit
import ProcessKit
import AgentKit
import SettingsKit
import PersistenceKit
import GitKit
@testable import Flotilla

/// Reproduction harness: drives the REAL process pipeline (real
/// `SystemPTYProcess`, real tmux binary, real server probe) with a
/// long-running `/bin/sleep` standing in for an agent CLI, to verify a
/// session's process actually stays running after creation.
@MainActor
final class RealPipelineReproTests: XCTestCase {
    private struct Locator: ExecutableLocating {
        var tmuxURL: URL?
        func locate(_ name: String) -> URL? {
            name == "tmux" ? tmuxURL : nil
        }
    }

    private func makeManager(useTmux: Bool) -> SessionProcessManager {
        var settings = AppSettings()
        settings.agentPaths.claudeCodePath = "/bin/sleep"
        settings.agentArguments.claudeCodeArguments = ["30"]
        return SessionProcessManager(
            locator: Locator(tmuxURL: useTmux ? URL(fileURLWithPath: "/opt/homebrew/bin/tmux") : nil),
            processFactory: SystemPTYProcessFactory(),
            settingsProvider: { settings }
        )
    }

    /// Regression for the poisoned-server failure: every tmux invocation must
    /// target Flotilla's dedicated socket (`-L flotilla`) — never the shared
    /// default server, whose stale clients can pin new panes to a deleted
    /// working directory, killing Bun-compiled agents with `getcwd()` ENOENT
    /// at startup.
    func testAllTmuxInvocationsUseDedicatedSocket() {
        let launch = TmuxSessionWrapping.wrap(
            agentExecutable: URL(fileURLWithPath: "/usr/local/bin/claude"),
            arguments: ["--effort", "medium"],
            environment: [:],
            workingDirectory: URL(fileURLWithPath: "/tmp"),
            sessionID: UUID(),
            tmuxExecutable: URL(fileURLWithPath: "/usr/local/bin/tmux")
        )
        XCTAssertEqual(Array(launch.arguments.prefix(2)), ["-L", TmuxSessionWrapping.socketName])
        XCTAssertTrue(launch.arguments.contains("new-session"))
        XCTAssertEqual(
            ProcessTmuxServerProbe.defaultSocketPath(),
            "/tmp/tmux-\(getuid())/\(TmuxSessionWrapping.socketName)"
        )
    }

    func testDirectLaunchStaysRunning() async throws {
        let manager = makeManager(useTmux: false)
        let session = Session(
            title: "Repro direct",
            goal: "Ignore me",
            agent: .claudeCode,
            projectID: nil,
            workingDirectory: URL(fileURLWithPath: "/tmp"),
            status: .idle
        )
        let process = try manager.start(session: session, deliverGoal: false)
        XCTAssertTrue(process.isRunning, "process must be running right after start")
        try await Task.sleep(for: .seconds(1.5))
        XCTAssertTrue(process.isRunning, "process must STILL be running after 1.5s")
        manager.terminate(sessionID: session.id)
    }

    func testTmuxWrappedLaunchStaysRunning() async throws {
        let manager = makeManager(useTmux: true)
        let session = Session(
            title: "Repro tmux",
            goal: "Ignore me",
            agent: .claudeCode,
            projectID: nil,
            workingDirectory: URL(fileURLWithPath: "/tmp"),
            status: .idle
        )
        let process = try manager.start(session: session, deliverGoal: false)
        XCTAssertTrue(process.isRunning, "process must be running right after start")
        try await Task.sleep(for: .seconds(1.5))
        XCTAssertTrue(process.isRunning, "process must STILL be running after 1.5s")
        manager.terminate(sessionID: session.id)
    }

    func testTmuxWrappedLaunchWithGoalStaysRunning() async throws {
        let manager = makeManager(useTmux: true)
        let session = Session(
            title: "Repro tmux goal",
            goal: "Ignore me",
            agent: .claudeCode,
            projectID: nil,
            workingDirectory: URL(fileURLWithPath: "/tmp"),
            status: .idle
        )
        let process = try manager.start(session: session, deliverGoal: true)
        XCTAssertTrue(process.isRunning, "process must be running right after start")
        try await Task.sleep(for: .seconds(1.5))
        XCTAssertTrue(process.isRunning, "process must STILL be running after 1.5s")
        manager.terminate(sessionID: session.id)
    }

    func testCreateSessionThroughStoreKeepsProcessRunning() async throws {
        var settings = AppSettings()
        settings.agentPaths.claudeCodePath = "/bin/sleep"
        settings.agentArguments.claudeCodeArguments = ["30"]
        let store = AppStore(
            repository: try GRDBSessionRepository(),
            gitService: MockGitService(),
            processManager: SessionProcessManager(
                locator: Locator(tmuxURL: URL(fileURLWithPath: "/opt/homebrew/bin/tmux")),
                processFactory: SystemPTYProcessFactory(),
                settingsProvider: { settings }
            ),
            worktreeBaseDirectoryProvider: { URL(fileURLWithPath: "/tmp/worktrees") }
        )

        await store.createSession(
            title: "Store repro",
            goal: "Ignore me",
            agent: .claudeCode,
            projectFolder: nil,
            checkoutMode: .mainCheckout
        )

        XCTAssertNil(store.lastCreationError, "creation error: \(store.lastCreationError ?? "")")
        let created = try XCTUnwrap(store.sessions.first { $0.title == "Store repro" })
        XCTAssertEqual(created.status, .working, "session must be .working, got \(created.status.rawValue)")
        let process = try XCTUnwrap(store.process(for: created.id), "process must exist for created session")
        XCTAssertTrue(process.isRunning, "process must be running right after creation")
        try await Task.sleep(for: .seconds(1.5))
        XCTAssertTrue(process.isRunning, "process must STILL be running after 1.5s")
        await store.deleteSession(sessionID: created.id, deleteWorktree: false)
    }

    /// Regression for "Restart Session does not work": restarting while the
    /// old process is still registered (SIGTERM sent, exit callback not yet
    /// delivered) must start a FRESH process — not return the dying one.
    func testRestartWhileOldProcessStillRegisteredStartsFreshProcess() async throws {
        var settings = AppSettings()
        settings.agentPaths.claudeCodePath = "/bin/sleep"
        settings.agentArguments.claudeCodeArguments = ["30"]
        let store = AppStore(
            repository: try GRDBSessionRepository(),
            gitService: MockGitService(),
            processManager: SessionProcessManager(
                locator: Locator(tmuxURL: nil),
                processFactory: SystemPTYProcessFactory(),
                settingsProvider: { settings }
            ),
            worktreeBaseDirectoryProvider: { URL(fileURLWithPath: "/tmp/worktrees") }
        )

        await store.createSession(
            title: "Restart race",
            goal: "",
            agent: .claudeCode,
            projectFolder: nil,
            checkoutMode: .mainCheckout
        )
        let created = try XCTUnwrap(store.sessions.first { $0.title == "Restart race" })
        let original = try XCTUnwrap(store.process(for: created.id))
        XCTAssertTrue(original.isRunning)

        store.restartSession(sessionID: created.id)

        let after = try XCTUnwrap(store.process(for: created.id), "restart must leave a registered process")
        XCTAssertFalse(after === original, "restart must not return the old dying process")
        try await Task.sleep(for: .seconds(1))
        XCTAssertTrue(store.process(for: created.id)?.isRunning == true, "restart must leave a running process")
        await store.deleteSession(sessionID: created.id, deleteWorktree: false)
    }

    /// Regression for "Restart Session does not work" on tmux-backed
    /// sessions: restarting must kill the server-side tmux session (whose
    /// agent pane may hold a dead or superseded agent) and recreate it
    /// fresh — plain `new-session -A` alone would just reattach to the old
    /// pane and the agent would never actually restart.
    func testTmuxRestartKillsOldSessionAndStartsFreshAgent() async throws {
        var settings = AppSettings()
        settings.agentPaths.claudeCodePath = "/bin/sleep"
        settings.agentArguments.claudeCodeArguments = ["30"]
        let store = AppStore(
            repository: try GRDBSessionRepository(),
            gitService: MockGitService(),
            processManager: SessionProcessManager(
                locator: Locator(tmuxURL: URL(fileURLWithPath: "/opt/homebrew/bin/tmux")),
                processFactory: SystemPTYProcessFactory(),
                settingsProvider: { settings }
            ),
            worktreeBaseDirectoryProvider: { URL(fileURLWithPath: "/tmp/worktrees") }
        )

        await store.createSession(
            title: "Tmux restart",
            goal: "",
            agent: .claudeCode,
            projectFolder: nil,
            checkoutMode: .mainCheckout
        )
        let created = try XCTUnwrap(store.sessions.first { $0.title == "Tmux restart" })
        let sessionName = TmuxSessionWrapping.sessionName(for: created.id)
        let originalPID = try XCTUnwrap(waitForTmuxPanePID(sessionName), "tmux session must exist after creation")

        store.restartSession(sessionID: created.id)

        let after = try XCTUnwrap(store.process(for: created.id))
        XCTAssertTrue(after.isRunning, "restart must leave a running process")
        try await Task.sleep(for: .seconds(1))
        XCTAssertTrue(store.process(for: created.id)?.isRunning == true)
        let freshPID = try XCTUnwrap(waitForTmuxPanePID(sessionName), "tmux session must exist after restart")
        XCTAssertNotEqual(freshPID, originalPID, "restart must recreate the tmux session (fresh agent pane), not reattach to the old pane")
        await store.deleteSession(sessionID: created.id, deleteWorktree: false)
    }

    /// Regression for the real-world restart flow: an agent that exits
    /// (finished or crashed) makes tmux destroy its session (`remain-on-exit`
    /// is off), which kills the attached client — the app's process — and
    /// leaves the session without a process. A restart must then create a
    /// fresh tmux session and a fresh agent, not reattach to nothing.
    func testRestartAfterAgentExitRecreatesFreshSession() async throws {
        var settings = AppSettings()
        settings.agentPaths.claudeCodePath = "/bin/sleep"
        settings.agentArguments.claudeCodeArguments = ["600"]
        let store = AppStore(
            repository: try GRDBSessionRepository(),
            gitService: MockGitService(),
            processManager: SessionProcessManager(
                locator: Locator(tmuxURL: URL(fileURLWithPath: "/opt/homebrew/bin/tmux")),
                processFactory: SystemPTYProcessFactory(),
                settingsProvider: { settings }
            ),
            worktreeBaseDirectoryProvider: { URL(fileURLWithPath: "/tmp/worktrees") }
        )

        await store.createSession(
            title: "Agent exit restart",
            goal: "",
            agent: .claudeCode,
            projectFolder: nil,
            checkoutMode: .mainCheckout
        )
        let created = try XCTUnwrap(store.sessions.first { $0.title == "Agent exit restart" })
        let sessionName = TmuxSessionWrapping.sessionName(for: created.id)
        let originalPID = try XCTUnwrap(waitForTmuxPanePID(sessionName))
        let process = try XCTUnwrap(store.process(for: created.id))
        XCTAssertTrue(process.isRunning)

        // Simulate the agent exiting: kill the pane's process. tmux destroys
        // the session, which kills the attached client — exactly what happens
        // when a real agent finishes or crashes.
        kill(Int32(originalPID)!, SIGKILL)

        var clientExited = false
        for _ in 0..<50 where !clientExited {
            if store.process(for: created.id) == nil { clientExited = true }
            try await Task.sleep(for: .milliseconds(100))
        }
        XCTAssertTrue(clientExited, "app-side client must exit when the agent dies")
        XCTAssertNil(waitForTmuxPanePID(sessionName), "tmux session must be destroyed when its agent exits")

        store.restartSession(sessionID: created.id)

        let restarted = try XCTUnwrap(store.process(for: created.id), "restart must register a fresh process")
        XCTAssertTrue(restarted.isRunning, "restart must leave a running process")
        try await Task.sleep(for: .seconds(1))
        XCTAssertTrue(store.process(for: created.id)?.isRunning == true, "restart must stay running")
        let freshPID = try XCTUnwrap(waitForTmuxPanePID(sessionName), "restart must recreate the tmux session")
        XCTAssertNotEqual(freshPID, originalPID, "restart must run a fresh agent, not reuse the dead one")
        await store.deleteSession(sessionID: created.id, deleteWorktree: false)
    }

    private func waitForTmuxPanePID(_ name: String) -> String? {
        for _ in 0..<100 {
            if let pid = tmuxPanePID(name) { return pid }
            Thread.sleep(forTimeInterval: 0.1)
        }
        return nil
    }

    /// Full end-to-end with the REAL Claude Code CLI (the same binary the app
    /// launches) under REAL tmux, through the AppStore: create, let claude
    /// boot, restart twice — the exact flow the user reported broken.
    func testRealClaudeCreateAndDoubleRestartKeepsRunning() async throws {
        let claudePath = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".local/bin/claude").path
        guard FileManager.default.isExecutableFile(atPath: claudePath) else {
            throw XCTSkip("real claude not installed")
        }
        var settings = AppSettings()
        settings.agentPaths.claudeCodePath = claudePath
        let store = AppStore(
            repository: try GRDBSessionRepository(),
            gitService: MockGitService(),
            processManager: SessionProcessManager(
                locator: Locator(tmuxURL: URL(fileURLWithPath: "/opt/homebrew/bin/tmux")),
                processFactory: SystemPTYProcessFactory(),
                settingsProvider: { settings }
            ),
            worktreeBaseDirectoryProvider: { URL(fileURLWithPath: "/tmp/worktrees") }
        )

        await store.createSession(
            title: "Real claude restart",
            goal: "",
            agent: .claudeCode,
            projectFolder: nil,
            checkoutMode: .mainCheckout
        )
        let created = try XCTUnwrap(store.sessions.first { $0.title == "Real claude restart" })
        let sessionName = TmuxSessionWrapping.sessionName(for: created.id)
        let firstPID = try XCTUnwrap(waitForTmuxPanePID(sessionName), "claude must have a pane")
        XCTAssertTrue(waitForPaneContent(sessionName), "claude must actually boot (pane must produce output)")

        store.restartSession(sessionID: created.id)
        let afterFirstRestart = try XCTUnwrap(store.process(for: created.id), "restart #1 must register a process")
        XCTAssertTrue(afterFirstRestart.isRunning)
        try await Task.sleep(for: .seconds(1))
        XCTAssertTrue(store.process(for: created.id)?.isRunning == true, "restart #1 must stay running")
        let secondPID = try XCTUnwrap(waitForTmuxPanePID(sessionName), "restart #1 must recreate the pane")
        XCTAssertNotEqual(secondPID, firstPID, "restart #1 must run a fresh claude")

        store.restartSession(sessionID: created.id)
        let afterSecondRestart = try XCTUnwrap(store.process(for: created.id), "restart #2 must register a process")
        XCTAssertTrue(afterSecondRestart.isRunning)
        try await Task.sleep(for: .seconds(1))
        XCTAssertTrue(store.process(for: created.id)?.isRunning == true, "restart #2 must stay running")
        let thirdPID = try XCTUnwrap(waitForTmuxPanePID(sessionName), "restart #2 must recreate the pane")
        XCTAssertNotEqual(thirdPID, secondPID, "restart #2 must run a fresh claude")

        await store.deleteSession(sessionID: created.id, deleteWorktree: false)
    }

    private func waitForPaneContent(_ name: String) -> Bool {
        for _ in 0..<150 {
            if let content = capturePane(name), !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return true
            }
            Thread.sleep(forTimeInterval: 0.2)
        }
        return false
    }

    private func capturePane(_ name: String) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/opt/homebrew/bin/tmux")
        process.arguments = ["-L", "flotilla", "capture-pane", "-p", "-t", name]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        try? process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(decoding: data, as: UTF8.self)
    }

    private func tmuxPanePID(_ name: String) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/opt/homebrew/bin/tmux")
        process.arguments = ["-L", "flotilla", "display-message", "-p", "-t", name, "#{pane_pid}"]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        try? process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let value = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }
}
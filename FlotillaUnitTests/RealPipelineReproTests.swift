import XCTest
import SessionKit
import ProcessKit
import AgentKit
import SettingsKit
import PersistenceKit
import GitKit
import HooksKit
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
        settings.agentPaths.claudeCodePath = "/bin/sh"
        settings.agentArguments.claudeCodeArguments = ["-c", "sleep 30", "--"]
        return SessionProcessManager(
            locator: Locator(tmuxURL: useTmux ? URL(fileURLWithPath: "/opt/homebrew/bin/tmux") : nil),
            processFactory: SystemPTYProcessFactory(),
            settingsProvider: { settings }
        )
    }

    /// The launcher script `wrap()` now generates must reproduce every
    /// argument byte-for-byte when the shell actually runs it — this drives
    /// the real `/bin/sh` on the generated script (bypassing tmux) with
    /// arguments containing single quotes, backticks, `$()`, `;`/`|`/`&`,
    /// and embedded newlines, and checks the executed command received them
    /// unmangled and without executing anything they might otherwise inject.
    func testGeneratedLaunchScriptPreservesTrickyArgumentsExactly() throws {
        let trickyArguments = [
            "plain",
            "it's a 'quoted' value",
            "`echo injected`",
            "$(echo injected)",
            "a; rm -rf /tmp/should-not-run; b",
            "pipe | to | somewhere & background",
            "multi\nline\nvalue",
            String(repeating: "B", count: 20_000)
        ]
        let tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("flotilla-quote-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDirectory) }

        let launch = TmuxSessionWrapping.wrap(
            agentExecutable: URL(fileURLWithPath: "/bin/echo"),
            arguments: trickyArguments,
            environment: [:],
            workingDirectory: tempDirectory,
            sessionID: UUID(),
            tmuxExecutable: URL(fileURLWithPath: "/opt/homebrew/bin/tmux"),
            supportDirectory: tempDirectory
        )

        // The generated command is the last two elements: ["/bin/sh", scriptPath].
        XCTAssertEqual(launch.arguments.suffix(2).first, "/bin/sh")
        let scriptPath = try XCTUnwrap(launch.arguments.last)
        XCTAssertTrue(FileManager.default.fileExists(atPath: scriptPath), "launcher script must be written to disk")

        // Run the generated script directly — no tmux involved — to prove the
        // shell reconstructs the exact same arguments /bin/echo was handed.
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = [scriptPath]
        let outputPipe = Pipe()
        process.standardOutput = outputPipe
        process.standardError = FileHandle.nullDevice
        try process.run()
        let data = outputPipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        XCTAssertEqual(process.terminationStatus, 0)
        XCTAssertEqual(String(decoding: data, as: UTF8.self), trickyArguments.joined(separator: " ") + "\n")
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: "/tmp/should-not-run"),
            "no argument content must ever be interpreted as a command to execute"
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

    /// `set-option -g` cannot reach a cold socket (a sessionless tmux server
    /// exits immediately), so the server options must ride along on the
    /// invocation that creates the first session — otherwise the first
    /// session after a reboot comes up with tmux's green status bar.
    func testColdServerLaunchCarriesGlobalOptionsAsConfigFile() throws {
        let configuration = URL(fileURLWithPath: "/tmp/flotilla-test/tmux.conf")
        let launch = TmuxSessionWrapping.wrap(
            agentExecutable: URL(fileURLWithPath: "/usr/local/bin/claude"),
            arguments: [],
            environment: [:],
            workingDirectory: URL(fileURLWithPath: "/tmp"),
            sessionID: UUID(),
            tmuxExecutable: URL(fileURLWithPath: "/usr/local/bin/tmux"),
            configurationFile: configuration
        )

        // `-f` is a client flag: it must precede the command, not follow it.
        let flagIndex = try XCTUnwrap(launch.arguments.firstIndex(of: "-f"))
        let commandIndex = try XCTUnwrap(launch.arguments.firstIndex(of: "new-session"))
        XCTAssertLessThan(flagIndex, commandIndex)
        XCTAssertEqual(launch.arguments[flagIndex + 1], configuration.path)
        XCTAssertEqual(Array(launch.arguments.prefix(2)), ["-L", TmuxSessionWrapping.socketName])

        let contents = TmuxSessionWrapping.configurationFileContents()
        XCTAssertTrue(contents.contains("set-option -g status off"))
        XCTAssertTrue(contents.contains("set-option -g default-terminal tmux-256color"))
    }

    func testDirectLaunchStaysRunning() async throws {
        let manager = makeManager(useTmux: false)
        let session = Session(
            title: "Repro direct",
            goal: "Ignore me",
            agent: .claudeCode,
            projectID: nil,
            workingDirectory: URL(fileURLWithPath: "/tmp"),
            status: nil
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
            status: nil
        )
        let process = try manager.start(session: session, deliverGoal: false)
        XCTAssertTrue(process.isRunning, "process must be running right after start")
        try await Task.sleep(for: .seconds(1.5))
        XCTAssertTrue(process.isRunning, "process must STILL be running after 1.5s")
        manager.terminate(sessionID: session.id)
    }

    func testCreateSessionThroughStoreKeepsProcessRunning() async throws {
        var settings = AppSettings()
        settings.agentPaths.claudeCodePath = "/bin/sh"
        settings.agentArguments.claudeCodeArguments = ["-c", "sleep 30", "--"]
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
        XCTAssertNil(created.status, "a just-launched session has no status until the pipeline observes it")
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
        settings.agentPaths.claudeCodePath = "/bin/sh"
        settings.agentArguments.claudeCodeArguments = ["-c", "sleep 30", "--"]
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
        settings.agentPaths.claudeCodePath = "/bin/sh"
        settings.agentArguments.claudeCodeArguments = ["-c", "sleep 30", "--"]
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
        settings.agentPaths.claudeCodePath = "/bin/sh"
        settings.agentArguments.claudeCodeArguments = ["-c", "sleep 600", "--"]
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

        // Simulate the agent exiting: kill the pane's process. With remain-on-exit on,
        // the pane enters dead state with the exit banner while remaining available for restart.
        kill(Int32(originalPID)!, SIGKILL)
        try await Task.sleep(for: .milliseconds(500))

        store.restartSession(sessionID: created.id)

        let restarted = try XCTUnwrap(store.process(for: created.id), "restart must register a fresh process")
        XCTAssertTrue(restarted.isRunning, "restart must leave a running process")
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertTrue(store.process(for: created.id)?.isRunning == true, "restart must stay running")
        let freshPID = try XCTUnwrap(waitForTmuxPanePID(sessionName), "restart must recreate the tmux session")
        XCTAssertNotEqual(freshPID, originalPID, "restart must run a fresh agent, not reuse the dead one")
        await store.deleteSession(sessionID: created.id, deleteWorktree: false)
    }

    /// `remain-on-exit` keeps a dead agent's pane — and the client attached
    /// to it — alive, so the process-exit path never fires. The session must
    /// still learn the agent is gone and how, or it keeps showing a live
    /// terminal with a one-line banner and a status that says nothing failed.
    func testAgentExitInsideTmuxIsConfirmedWithItsExitCodeAndClearedByRestart() async throws {
        var settings = AppSettings()
        settings.agentPaths.claudeCodePath = "/bin/sh"
        settings.agentArguments.claudeCodeArguments = ["-c", "sleep 2; exit 3", "--"]
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
            title: "Agent exit screen",
            goal: "",
            agent: .claudeCode,
            projectFolder: nil,
            checkoutMode: .mainCheckout
        )
        let created = try XCTUnwrap(store.sessions.first { $0.title == "Agent exit screen" })
        let sessionName = TmuxSessionWrapping.sessionName(for: created.id)
        let confirmedWhileRunning = await store.confirmAgentExit(sessionID: created.id)
        XCTAssertFalse(confirmedWhileRunning, "a live agent must not be reported as exited")

        let banner = try XCTUnwrap(waitForTmuxPaneBanner(sessionName), "tmux must draw its dead-pane banner")
        XCTAssertEqual(
            TerminalScreenHeuristic().observation(forScreen: banner)?.suggestsAgentExit,
            true,
            "the banner tmux actually draws must be one the screen heuristic recognises"
        )
        XCTAssertTrue(store.process(for: created.id)?.isRunning == true, "the client stays attached to the dead pane")

        let confirmed = await store.confirmAgentExit(sessionID: created.id)

        XCTAssertTrue(confirmed)
        XCTAssertEqual(store.agentExit(for: created.id), .status(3))
        XCTAssertEqual(store.sessions.first { $0.id == created.id }?.status, .crashed)

        store.restartSession(sessionID: created.id)

        XCTAssertNil(store.agentExit(for: created.id), "a restarted agent must not keep the previous exit screen")
        await store.deleteSession(sessionID: created.id, deleteWorktree: false)
    }

    func testPaneStateParsingDistinguishesLiveStatusAndSignalDeaths() {
        XCTAssertNil(TmuxPaneExit(paneStateLine: "0  \n"))
        XCTAssertEqual(TmuxPaneExit(paneStateLine: "1 0 \n"), .status(0))
        XCTAssertEqual(TmuxPaneExit(paneStateLine: "1 3 \n"), .status(3))
        // tmux 3.7 names the signal and leaves the status empty; older
        // releases report the number.
        XCTAssertEqual(TmuxPaneExit(paneStateLine: "1  kill\n"), .signal("kill"))
        XCTAssertEqual(TmuxPaneExit(paneStateLine: "1  9\n"), .signal("9"))
        XCTAssertFalse(TmuxPaneExit.signal("kill").succeeded)
    }

    /// Regression for "large prompt instantly crashes the new session": the
    /// goal is delivered as a bare argv element to the agent CLI
    /// (`CLIAgentProvider.launchPlan`), which used to land inline inside
    /// tmux's own `new-session -- <agent> <goal>` command. tmux has a hard
    /// internal ceiling (~16KB) on that command's total serialized length,
    /// far below the OS's own ARG_MAX — a goal past that ceiling made
    /// `new-session` itself fail with "command too long" and exit
    /// immediately, which the app observed as the brand-new session
    /// crashing on the spot. `TmuxSessionWrapping` now routes the agent
    /// launch through a generated `/bin/sh` script instead of inlining it
    /// into tmux's own command line, so tmux's short ceiling no longer
    /// applies — this asserts a 20 KB goal (well past the old ceiling)
    /// launches and keeps running.
    func testLargeGoalDoesNotCrashNewSession() async throws {
        var settings = AppSettings()
        settings.agentPaths.claudeCodePath = "/bin/sh"
        settings.agentArguments.claudeCodeArguments = ["-c", "sleep 30", "--"]
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

        let largeGoal = String(repeating: "A", count: 20_000)
        await store.createSession(
            title: "Large goal repro",
            goal: largeGoal,
            agent: .claudeCode,
            projectFolder: nil,
            checkoutMode: .mainCheckout
        )

        let created = try XCTUnwrap(store.sessions.first { $0.title == "Large goal repro" })
        let process = try XCTUnwrap(store.process(for: created.id), "process must exist right after creation")

        // Give the pipeline a moment to observe a premature exit, if any.
        try await Task.sleep(for: .seconds(1.5))

        XCTAssertTrue(process.isRunning, "a 20KB goal must not make tmux's own command line too long to launch")
        let refetched = try XCTUnwrap(store.sessions.first { $0.id == created.id })
        XCTAssertNotEqual(refetched.status, .crashed, "session must not be marked crashed for an oversized goal")
        await store.deleteSession(sessionID: created.id, deleteWorktree: false)
    }

    private func waitForTmuxPaneBanner(_ name: String, timeout: TimeInterval = 10.0) -> String? {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/opt/homebrew/bin/tmux")
            process.arguments = TmuxSessionWrapping.socketArguments() + ["capture-pane", "-p", "-t", name]
            let output = Pipe()
            process.standardOutput = output
            process.standardError = FileHandle.nullDevice
            try? process.run()
            let screen = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            process.waitUntilExit()
            if screen.contains("Agent exited") { return screen }
            Thread.sleep(forTimeInterval: 0.1)
        }
        return nil
    }

    private func waitForTmuxPanePID(_ name: String, timeout: TimeInterval = 10.0) -> String? {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let pid = tmuxPanePID(name) { return pid }
            Thread.sleep(forTimeInterval: 0.05)
        }
        return nil
    }

    private func waitForTmuxPaneToDisappear(_ name: String, timeout: TimeInterval = 6.0) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if tmuxPanePID(name) == nil { return true }
            Thread.sleep(forTimeInterval: 0.05)
        }
        return tmuxPanePID(name) == nil
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
        // A dedicated temp folder, NOT `generalSessionWorkingDirectory()`:
        // real Claude Code refuses to start a second instance inside a
        // directory where another claude is already running (the user's own
        // app may have a general session there), and this test must be able
        // to run while the app is in use.
        let testDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("flotilla-real-claude-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: testDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: testDirectory) }
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
            projectFolder: testDirectory,
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
        process.arguments = TmuxSessionWrapping.socketArguments() + ["capture-pane", "-p", "-t", name]
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
        process.arguments = TmuxSessionWrapping.socketArguments() + ["display-message", "-p", "-t", name, "#{pane_pid}"]
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
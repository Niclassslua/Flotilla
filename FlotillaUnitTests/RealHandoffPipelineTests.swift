import XCTest
import SessionKit
import ProcessKit
import SettingsKit
@testable import TranscriptKit
@testable import Flotilla

/// Drives a handoff through the REAL process pipeline — real `SystemPTYProcess`,
/// real tmux binary, real transcript files — with `/bin/sh` standing in for the
/// agent CLIs.
///
/// This exists for one assertion the mocked tests structurally cannot make.
/// `SessionProcessManager.start` short-circuits when a tmux session already
/// exists: `new-session -A` reattaches to the live pane and never runs the
/// command after `--`. A handoff that failed to destroy the server-side session
/// would therefore *look* successful — no error, a PTY attaches, the terminal
/// renders — while the old agent kept running against the new transcript. The
/// only way to catch that is to ask tmux what it is actually running.
@MainActor
final class RealHandoffPipelineTests: XCTestCase {
    private struct Locator: ExecutableLocating {
        let tmuxURL: URL?
        func locate(_ name: String) -> URL? { name == "tmux" ? tmuxURL : nil }
    }

    private var home: URL!
    private var workingDirectory: URL!
    private var sessionID: UUID!
    private var tmuxURL: URL!

    /// The two stand-in agents differ only in how long they sleep, which is
    /// what makes tmux's own record of the pane's command decisive.
    private static let claudeCommand = "sleep 31"
    private static let codexCommand = "sleep 32"

    override func setUp() async throws {
        try await super.setUp()
        let candidates = ["/opt/homebrew/bin/tmux", "/usr/local/bin/tmux", "/usr/bin/tmux"]
        guard let found = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) else {
            throw XCTSkip("tmux is not installed; the real pipeline cannot be exercised")
        }
        tmuxURL = URL(fileURLWithPath: found)
        sessionID = UUID()
        home = FileManager.default.temporaryDirectory
            .appendingPathComponent("RealHandoff-\(UUID().uuidString)", isDirectory: true)
        workingDirectory = home.appendingPathComponent("project", isDirectory: true)
        try FileManager.default.createDirectory(at: workingDirectory, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        killTmuxSession()
        try? FileManager.default.removeItem(at: home)
        try await super.tearDown()
    }

    // MARK: - tmux interrogation

    private func tmux(_ arguments: [String]) -> String {
        let process = Process()
        process.executableURL = tmuxURL
        process.arguments = ["-L", TmuxSessionWrapping.socketName] + arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        try? process.run()
        process.waitUntilExit()
        return String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    private var tmuxSessionName: String { TmuxSessionWrapping.sessionName(for: sessionID) }

    /// What tmux itself believes this session's pane was launched to run.
    private func paneStartCommand() -> String {
        tmux(["list-panes", "-t", tmuxSessionName, "-F", "#{pane_start_command}"])
    }

    private func killTmuxSession() {
        _ = tmux(["kill-session", "-t", tmuxSessionName])
    }

    // MARK: - Fixtures

    private func makeManager() -> SessionProcessManager {
        var settings = AppSettings()
        settings.agentOverrides.paths["claudeCode"] = "/bin/sh"
        settings.agentOverrides.arguments["claudeCode"] = ["-c", Self.claudeCommand, "--"]
        settings.agentOverrides.paths["codexCLI"] = "/bin/sh"
        settings.agentOverrides.arguments["codexCLI"] = ["-c", Self.codexCommand, "--"]
        return SessionProcessManager(
            locator: Locator(tmuxURL: tmuxURL),
            processFactory: SystemPTYProcessFactory(),
            settingsProvider: { settings }
        )
    }

    private func seedClaudeTranscript(nativeID: String) throws -> URL {
        let directory = home
            .appendingPathComponent(".claude/projects", isDirectory: true)
            .appendingPathComponent(
                ClaudeTranscriptCodec.projectSlug(for: workingDirectory),
                isDirectory: true
            )
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = directory.appendingPathComponent("\(nativeID).jsonl")
        let lines = [
            #"{"type":"user","uuid":"u1","sessionId":"\#(nativeID)","timestamp":"2026-09-08T01:18:36Z","message":{"role":"user","content":"list the files"}}"#,
            #"{"type":"assistant","uuid":"a1","parentUuid":"u1","sessionId":"\#(nativeID)","timestamp":"2026-09-08T01:18:37Z","message":{"role":"assistant","content":[{"type":"text","text":"on it"}]}}"#
        ]
        try lines.joined(separator: "\n").write(to: file, atomically: true, encoding: .utf8)
        return file
    }

    // MARK: - The test

    func testHandoffReplacesTheRunningAgentUnderRealTmux() async throws {
        let manager = makeManager()
        let nativeID = sessionID.uuidString
        let sourceTranscript = try seedClaudeTranscript(nativeID: nativeID)

        var session = Session(
            id: sessionID,
            title: "Real handoff",
            goal: "Move me",
            agent: .claudeCode,
            projectID: nil,
            workingDirectory: workingDirectory,
            status: .working,
            agentSessionID: nativeID,
            nativeTranscriptPath: sourceTranscript
        )

        try manager.start(session: session, deliverGoal: false)
        // tmux creates the session asynchronously from our point of view.
        try await Task.sleep(for: .milliseconds(900))

        XCTAssertTrue(
            paneStartCommand().contains(Self.claudeCommand),
            "expected the source agent to be running, got: \(paneStartCommand())"
        )

        let claude = ClaudeTranscriptCodec(homeDirectory: home)
        let codex = CodexTranscriptCodec(homeDirectory: home)
        let readers: [any TranscriptReading] = [claude, codex]
        let writers: [any TranscriptWriting] = [claude, codex]
        let service = HandoffService(
            processManager: manager,
            registry: TranscriptCodecRegistry(readers: readers, writers: writers)
        )

        let plan = try service.plan(for: session, to: .codexCLI)
        session = try await service.perform(plan)
        try await Task.sleep(for: .milliseconds(900))

        // The decisive assertion: tmux is running the *destination* agent.
        let afterHandoff = paneStartCommand()
        XCTAssertTrue(
            afterHandoff.contains(Self.codexCommand),
            "tmux still runs the source agent — the server-side session was not destroyed. Got: \(afterHandoff)"
        )
        XCTAssertFalse(afterHandoff.contains(Self.claudeCommand))

        XCTAssertEqual(session.agent, .codexCLI)
        XCTAssertNotNil(manager.process(for: sessionID), "the destination process is attached")

        // The source survives probation, so a failed destination is recoverable.
        XCTAssertTrue(FileManager.default.fileExists(atPath: sourceTranscript.path))
        let written = try XCTUnwrap(session.nativeTranscriptPath)
        XCTAssertTrue(FileManager.default.fileExists(atPath: written.path))

        // Settling releases the source.
        let settled = service.finalize(session)
        XCTAssertNil(settled.pendingHandoff)
        XCTAssertFalse(FileManager.default.fileExists(atPath: sourceTranscript.path))

        manager.terminate(sessionID: sessionID)
    }
}

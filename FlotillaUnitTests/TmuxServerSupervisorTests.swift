import XCTest
@testable import Flotilla

@MainActor
final class TmuxServerSupervisorTests: XCTestCase {
    private var tmuxURL: URL!

    override func setUpWithError() throws {
        let candidates = ["/opt/homebrew/bin/tmux", "/usr/local/bin/tmux", "/usr/bin/tmux"]
        guard let found = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) else {
            throw XCTSkip("tmux is not installed")
        }
        tmuxURL = URL(fileURLWithPath: found)
    }

    func testEnsureRunningStartsNonDaemonChild() throws {
        killServer()
        waitUntilServerGone()

        // Unique socket via XCTestCase branch in TmuxSessionWrapping.socketName.
        let supervisor = TmuxServerSupervisor()
        defer {
            supervisor.shutdown()
            killServer()
        }

        let status = supervisor.ensureRunning(tmuxExecutable: tmuxURL)
        XCTAssertEqual(status, .runningUnderFlotilla)
        XCTAssertNil(supervisor.orphanWarning)

        let pid = try XCTUnwrap(TmuxServerSupervisor.serverPID(tmuxExecutable: tmuxURL))
        let ppid = try XCTUnwrap(TmuxServerSupervisor.parentPID(of: pid))
        XCTAssertEqual(ppid, getpid(), "tmux -D must stay a child of Flotilla for TCC attribution")
    }

    func testOrphanedDaemonIsReusedNotKilled() throws {
        // Clear any -D server left by a sibling test on the shared XCTest socket.
        killServer()
        waitUntilServerGone()

        // Old Flotilla path: a client forks a daemon (ppid 1). Run via /bin/sh
        // so the client exits and the server is reparented to launchd.
        let boot = Process()
        boot.executableURL = URL(fileURLWithPath: "/bin/sh")
        boot.arguments = [
            "-c",
            "'\(tmuxURL.path)' -L \(TmuxSessionWrapping.socketName) new-session -d -s orphan-probe sleep 30"
        ]
        boot.standardOutput = FileHandle.nullDevice
        boot.standardError = FileHandle.nullDevice
        try boot.run()
        boot.waitUntilExit()
        defer { killServer() }

        let orphanPID = try XCTUnwrap(
            waitForServerPID(),
            "daemonized server should answer after new-session -d"
        )
        let orphanPPID = try XCTUnwrap(TmuxServerSupervisor.parentPID(of: orphanPID))
        guard orphanPPID == 1 else {
            throw XCTSkip("tmux did not daemonize onto launchd (ppid \(orphanPPID)); cannot exercise orphan path")
        }

        let supervisor = TmuxServerSupervisor()
        let status = supervisor.ensureRunning(tmuxExecutable: tmuxURL)
        XCTAssertEqual(status, .reusingOrphanedServer)
        XCTAssertNotNil(supervisor.orphanWarning)
        XCTAssertEqual(
            TmuxServerSupervisor.serverPID(tmuxExecutable: tmuxURL),
            orphanPID,
            "must not kill the orphaned server (live agent sessions)"
        )
        supervisor.shutdown()
        XCTAssertEqual(
            TmuxServerSupervisor.serverPID(tmuxExecutable: tmuxURL),
            orphanPID,
            "shutdown must leave an orphaned server alone"
        )
    }

    private func killServer() {
        let kill = Process()
        kill.executableURL = tmuxURL
        kill.arguments = TmuxSessionWrapping.socketArguments() + ["kill-server"]
        kill.standardOutput = FileHandle.nullDevice
        kill.standardError = FileHandle.nullDevice
        try? kill.run()
        kill.waitUntilExit()
    }

    private func waitUntilServerGone() {
        let deadline = Date().addingTimeInterval(2)
        while Date() < deadline, TmuxServerSupervisor.serverPID(tmuxExecutable: tmuxURL) != nil {
            Thread.sleep(forTimeInterval: 0.05)
        }
    }

    private func waitForServerPID() -> pid_t? {
        let deadline = Date().addingTimeInterval(2)
        while Date() < deadline {
            if let pid = TmuxServerSupervisor.serverPID(tmuxExecutable: tmuxURL) { return pid }
            Thread.sleep(forTimeInterval: 0.05)
        }
        return nil
    }
}

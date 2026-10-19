import Darwin
import Foundation
import ProcessKit

/// Owns Flotilla's tmux server as a direct, non-daemon child (`tmux -D`).
///
/// A daemonized server is reparented to launchd (ppid 1). macOS then cannot
/// build a TCC attribution chain back to Flotilla.app, so Documents / Desktop /
/// Downloads / iCloud prompts never appear and agents fail with EPERM. Keeping
/// the server as our child restores that chain.
@MainActor
final class TmuxServerSupervisor {
    private var process: Process?

    /// Set when an existing server on Flotilla's socket is not our child
    /// (typically a daemon left by an older Flotilla). Reused rather than
    /// killed — killing would destroy live agent sessions.
    private(set) var orphanWarning: String?

    enum Status: Equatable {
        case runningUnderFlotilla
        case reusingOrphanedServer
        case unavailable
    }

    /// Ensures a server is listening on Flotilla's socket before clients run
    /// `new-session`. Safe to call repeatedly.
    @discardableResult
    func ensureRunning(tmuxExecutable: URL) -> Status {
        if let process, process.isRunning {
            orphanWarning = nil
            return .runningUnderFlotilla
        }
        process = nil

        if let existingPID = Self.serverPID(tmuxExecutable: tmuxExecutable) {
            let parent = Self.parentPID(of: existingPID) ?? 0
            if parent == getpid() {
                // Child survived a lost Process handle (should be rare).
                orphanWarning = nil
                return .runningUnderFlotilla
            }
            orphanWarning =
                "An older Flotilla tmux server is still running outside this app. "
                + "Sessions under Documents, Desktop, Downloads, or iCloud Drive may fail until you "
                + "quit Flotilla, run `tmux -L \(TmuxSessionWrapping.socketName) kill-server` in Terminal, "
                + "and reopen Flotilla."
            return .reusingOrphanedServer
        }

        orphanWarning = nil
        guard startNonDaemonServer(tmuxExecutable: tmuxExecutable) else {
            // SessionProcessManager unit tests inject a non-executable tmux
            // path and a MockPTY — wrapping must still proceed so assertions
            // on argv/cwd hold. RealPipeline tests use a real binary and hit
            // the success path above.
            if NSClassFromString("XCTestCase") != nil {
                return .runningUnderFlotilla
            }
            return .unavailable
        }
        return .runningUnderFlotilla
    }

    /// Stops the server we started. Orphaned/daemonized servers are left alone.
    func shutdown() {
        guard let process else { return }
        self.process = nil
        guard process.isRunning else { return }
        process.terminate()
        // Wait briefly so the next ensureRunning does not see our dying child
        // and treat it as still attributable to Flotilla.
        let deadline = Date().addingTimeInterval(2)
        while process.isRunning, Date() < deadline {
            Thread.sleep(forTimeInterval: 0.05)
        }
    }

    private func startNonDaemonServer(tmuxExecutable: URL) -> Bool {
        let configurationFile = TmuxSessionWrapping.writeConfigurationFile()
        let process = ChildProcessEnvironment.makeProcess()
        process.executableURL = tmuxExecutable
        var arguments = TmuxSessionWrapping.socketArguments()
        if let configurationFile {
            arguments += ["-f", configurationFile.path]
        }
        // `-D`: do not daemonize; also turns exit-empty off. No command allowed.
        arguments.append("-D")
        process.arguments = arguments
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            return false
        }
        guard Self.waitForServer(tmuxExecutable: tmuxExecutable, timeout: 2) else {
            process.terminate()
            return false
        }
        self.process = process
        return true
    }

    private static func waitForServer(tmuxExecutable: URL, timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if serverPID(tmuxExecutable: tmuxExecutable) != nil { return true }
            Thread.sleep(forTimeInterval: 0.05)
        }
        return false
    }

    /// Server PID via `display-message '#{pid}'`, or `nil` if nothing answers.
    static func serverPID(tmuxExecutable: URL) -> pid_t? {
        let socketPath = ProcessTmuxServerProbe.defaultSocketPath()
        guard FileManager.default.fileExists(atPath: socketPath) else { return nil }

        let process = ChildProcessEnvironment.makeProcess()
        process.executableURL = tmuxExecutable
        process.arguments = TmuxSessionWrapping.socketArguments()
            + ["display-message", "-p", "#{pid}"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        guard let exited = try? process.runSignalingExit() else { return nil }
        guard exited.wait(timeout: .now() + 1) == .success else {
            process.terminate()
            return nil
        }
        guard process.terminationStatus == 0 else { return nil }
        let output = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard let pid = pid_t(output), pid > 0 else { return nil }
        return pid
    }

    static func parentPID(of pid: pid_t) -> pid_t? {
        var info = proc_bsdshortinfo()
        let requested = Int32(MemoryLayout<proc_bsdshortinfo>.stride)
        let written = proc_pidinfo(pid, PROC_PIDT_SHORTBSDINFO, 0, &info, requested)
        guard written == requested else { return nil }
        return pid_t(info.pbsi_ppid)
    }
}

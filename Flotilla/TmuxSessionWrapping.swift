import Foundation

/// Wraps an agent launch in `tmux new-session -A`, which creates the named
/// session if it doesn't exist or attaches to it if it already does. Because
/// tmux runs as a server independent of Flotilla, a session launched this way
/// survives Flotilla quitting and relaunching — the exact same command line
/// serves both the fresh-launch and reattach-after-relaunch cases.
enum TmuxSessionWrapping {
    /// Flotilla never talks to the machine's shared default tmux server
    /// (`$TMUX_TMPDIR/default`): that server can be poisoned by stale clients
    /// (e.g. an old Flotilla client left attached to a since-deleted worktree
    /// directory, which pins every subsequently created pane to that deleted
    /// cwd — processes that need `getcwd()` at startup, like Bun-compiled
    /// agent CLIs, then die instantly). A dedicated socket gives Flotilla a
    /// server whose only clients are its own, with state it fully controls.
    /// `-L` resolves to `$TMUX_TMPDIR/flotilla`, which is already
    /// per-user (`/tmp/tmux-<uid>/flotilla`).
    static let socketName = "flotilla"

    /// Client flags (`-L <socket>`) that must precede the tmux command.
    static func socketArguments() -> [String] {
        ["-L", socketName]
    }

    static func sessionName(for sessionID: UUID) -> String {
        "flotilla-\(sessionID.uuidString)"
    }

    /// tmux — unlike the agent CLIs it hosts — needs a `TERM` it can
    /// actually resolve to know how to draw itself; an inherited value like
    /// `dumb` (which e.g. Xcode's own build/test tooling sets, and which
    /// `CLIAgentProvider` otherwise only fills in when `TERM` is *absent*,
    /// not when it's present-but-unusable) makes tmux fail outright rather
    /// than degrade gracefully the way the agent CLIs do. This is always a
    /// safe, correct value here regardless of what's inherited: what tmux is
    /// actually drawing to is always Flotilla's own PTY, rendered by
    /// SwiftTerm, which genuinely is xterm-256color-compatible.
    private static let outerClientTERM = "xterm-256color"

    /// Returns the agent launch unchanged when tmux is unavailable.
    static func wrap(
        agentExecutable: URL,
        arguments: [String],
        environment: [String: String],
        workingDirectory: URL,
        sessionID: UUID,
        tmuxExecutable: URL?
    ) -> (executable: URL, arguments: [String], environment: [String: String]) {
        guard let tmuxExecutable else {
            return (agentExecutable, arguments, environment)
        }
        // The `default-terminal` option is set via a separate synchronous
        // `tmux set-option -g default-terminal tmux-256color` call in
        // `SessionProcessManager.start()` before this wrapper is invoked.
        // This avoids unreliable `;` command chaining in argv.
        let wrapped = socketArguments() + [
            "new-session", "-A", "-s", sessionName(for: sessionID),
            "-c", workingDirectory.path,
            "--", agentExecutable.path
        ] + arguments
        var wrappedEnvironment = environment
        wrappedEnvironment["TERM"] = outerClientTERM
        return (tmuxExecutable, wrapped, wrappedEnvironment)
    }
}

/// Seam for explicitly destroying a session's tmux server-side state.
/// Detaching the outer client (a plain `terminate()` on its `Process`) only
/// disconnects that client — the tmux session and the agent inside it keep
/// running, which is what we want on an ordinary app quit. Real session
/// deletion needs this instead, or the tmux session leaks forever.
protocol TmuxSessionTerminating: Sendable {
    func killSession(named name: String, tmuxExecutable: URL)
}

/// Seam for checking whether the tmux server Flotilla would talk to actually
/// answers clients. A long-lived server can wedge — it stays alive, accepts
/// a connection, then drops it ("server exited unexpectedly") — and in that
/// state every `new-session -A` exits 1 immediately: sessions report crashed
/// and restarts retry the same doomed command forever. Callers use the
/// verdict to fall back to launching the agent directly (losing only
/// quit/relaunch persistence for that session).
protocol TmuxServerProbing: Sendable {
    func serverIsUsable(tmuxExecutable: URL) -> Bool
}

struct ProcessTmuxServerProbe: TmuxServerProbing {
    /// Conservative by construction: only the observed wedge signature
    /// changes behavior; every other outcome preserves the tmux-wrapped path.
    func serverIsUsable(tmuxExecutable: URL) -> Bool {
        // No socket file => no server is running, and `new-session` will
        // auto-start a fresh one — nothing to probe. (Probing anyway would
        // spawn a throwaway server just to answer `ls`.)
        guard FileManager.default.fileExists(atPath: Self.defaultSocketPath()) else { return true }

        let process = Process()
        process.executableURL = tmuxExecutable
        process.arguments = TmuxSessionWrapping.socketArguments() + ["ls"]
        let errorPipe = Pipe()
        process.standardOutput = FileHandle.nullDevice
        process.standardError = errorPipe
        do {
            try process.run()
        } catch {
            // The probe itself failed to run — that says nothing about the
            // server, so keep the existing behavior (try tmux).
            return true
        }

        // A wedged server drops the client immediately, but a *hung* one
        // must not block the caller: bound the wait, and treat a timeout as
        // "not answering" too.
        let done = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            process.waitUntilExit()
            done.signal()
        }
        guard done.wait(timeout: .now() + 2) == .success else {
            process.terminate()
            return false
        }

        guard process.terminationStatus != 0 else { return true }
        let stderr = String(decoding: errorPipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        return !stderr.contains("server exited unexpectedly")
    }

    /// The socket Flotilla's tmux invocations use: `$TMUX_TMPDIR/flotilla`,
    /// falling back to tmux's compiled-in `/tmp/tmux-<uid>/flotilla`.
    /// Deliberately not the plain `default` socket — see `socketName`.
    static func defaultSocketPath(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> String {
        let directory = environment["TMUX_TMPDIR"] ?? "/tmp/tmux-\(getuid())"
        return directory + "/" + TmuxSessionWrapping.socketName
    }
}

struct ProcessTmuxSessionTerminator: TmuxSessionTerminating {
    func killSession(named name: String, tmuxExecutable: URL) {
        let process = Process()
        process.executableURL = tmuxExecutable
        process.arguments = TmuxSessionWrapping.socketArguments() + ["kill-session", "-t", name]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        // Best-effort: a missing session (never tmux-backed, or already
        // gone) just fails silently — there's nothing to clean up either way.
        // Synchronous on purpose: callers (session restart) immediately run
        // `new-session -A` with the same name, and an in-flight kill landing
        // after that would kill the freshly created session.
        try? process.run()
        process.waitUntilExit()
    }
}

/// Seam for delivering a session's initial goal into a tmux-wrapped pane.
///
/// A raw PTY write (`process.send(input:)`) reliably *types* the goal into
/// Claude Code's or Codex's composer but does not reliably *submit* it —
/// confirmed against both real CLIs across many combinations of trailing
/// byte (`\n`/`\r`), timing, and even explicit bracketed-paste framing: the
/// TUI treats a bulk write as paste-like content that needs a genuine,
/// separately-delivered keystroke to confirm. `tmux send-keys` — a control
/// command the tmux *server* injects directly into the pane, not a raw
/// terminal write at all — doesn't have this problem.
///
/// Implementations are expected to block their calling thread (waiting for
/// the pane to actually be ready, running `send-keys` synchronously) —
/// callers must invoke this off the main actor.
protocol TmuxGoalDelivering: Sendable {
    func deliverGoal(_ goal: String, toSessionNamed name: String, tmuxExecutable: URL)
}

struct ProcessTmuxGoalDeliverer: TmuxGoalDelivering {
    func deliverGoal(_ goal: String, toSessionNamed name: String, tmuxExecutable: URL) {
        // The agent CLI takes a real moment to boot (auth checks, MCP
        // server discovery, etc.) before it's actually listening for
        // input — send-keys arriving before then is silently dropped, not
        // queued. Wait for the pane to stop changing (a proxy for "the
        // splash/loading UI has settled") rather than guessing a fixed
        // delay that would either be too short for a slow boot or add
        // needless latency to a fast one.
        waitForPaneToStabilize(sessionName: name, tmuxExecutable: tmuxExecutable)

        // Two separate invocations, matching the verified-working manual
        // sequence: the literal text lands in the composer, then Enter — as
        // its own distinct injection — is what actually submits it.
        runSendKeys(["-t", name, "-l", goal], tmuxExecutable: tmuxExecutable)
        runSendKeys(["-t", name, "Enter"], tmuxExecutable: tmuxExecutable)
    }

    private func waitForPaneToStabilize(sessionName: String, tmuxExecutable: URL) {
        let deadline = Date().addingTimeInterval(10)
        var previous: String?
        var stableStreak = 0
        while Date() < deadline {
            let current = capturePane(sessionName: sessionName, tmuxExecutable: tmuxExecutable)
            if let current, current == previous {
                stableStreak += 1
                if stableStreak >= 2 { return } // unchanged across ~600ms
            } else {
                stableStreak = 0
            }
            previous = current
            Thread.sleep(forTimeInterval: 0.3)
        }
    }

    private func capturePane(sessionName: String, tmuxExecutable: URL) -> String? {
        let process = Process()
        process.executableURL = tmuxExecutable
        process.arguments = TmuxSessionWrapping.socketArguments()
            + ["capture-pane", "-p", "-t", sessionName]
        let outputPipe = Pipe()
        process.standardOutput = outputPipe
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            let data = outputPipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            return String(decoding: data, as: UTF8.self)
        } catch {
            return nil
        }
    }

    private func runSendKeys(_ arguments: [String], tmuxExecutable: URL) {
        let process = Process()
        process.executableURL = tmuxExecutable
        process.arguments = TmuxSessionWrapping.socketArguments() + ["send-keys"] + arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            // Best-effort: worst case the goal is left sitting typed but
            // unsubmitted, matching today's known behavior rather than
            // silently losing it.
        }
    }
}

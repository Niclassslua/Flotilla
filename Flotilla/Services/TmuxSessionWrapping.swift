import Foundation
import ProcessKit

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
    static var socketName: String {
        if let custom = ProcessInfo.processInfo.environment["FLOTILLA_TMUX_SOCKET"] {
            return custom
        }
        if NSClassFromString("XCTestCase") != nil {
            return "flotilla-test-\(ProcessInfo.processInfo.processIdentifier)"
        }
        return "flotilla"
    }

    /// Client flags (`-L <socket>`) that must precede the tmux command.
    static func socketArguments() -> [String] {
        ["-L", socketName]
    }

    static func sessionName(for sessionID: UUID) -> String {
        "flotilla-\(sessionID.uuidString)"
    }

    /// Server-wide options applied before any session is created.
    ///
    /// `status off` hides tmux's own status bar. Flotilla already draws the
    /// session's name, branch, and agent in its chrome, so the bar was a
    /// duplicate — and being tmux's, it rendered as a black-on-green strip
    /// pinned to the window's bottom row, redrawn every minute by its clock.
    /// Turning it off also hands that row back to the agent.
    static let globalOptions: [[String]] = [
        ["default-terminal", "tmux-256color"],
        ["status", "off"],
        ["history-limit", "50000"],
        ["mouse", "on"],
        ["remain-on-exit", "on"],
        ["remain-on-exit-format", "\"[Agent exited with status #{pane_dead_status} — click Restart Session to resume]\""],
    ]

    /// `set-option -g` needs a server that is already running, and on a cold
    /// socket there is no way to pre-start one to receive the options: a tmux
    /// server with no sessions exits immediately, taking them with it. The
    /// options therefore have to reach the very invocation that creates the
    /// first session, which is what `-f` does — tmux reads the file when it
    /// starts the server. Without this, the first session after a reboot (or
    /// after `kill-server`) launched with the green status bar still visible.
    ///
    /// `-f` is ignored when the server is already up; the `set-option -g`
    /// calls in `SessionProcessManager.start()` cover that case.
    static func configurationFileContents() -> String {
        globalOptions
            .map { "set-option -g " + $0.joined(separator: " ") }
            .joined(separator: "\n") + "\n"
    }

    /// Writes the server config next to Flotilla's other support files and
    /// returns its path, or `nil` if it could not be written — callers then
    /// fall back to the `set-option -g` path alone rather than failing a
    /// launch over a cosmetic option.
    static func writeConfigurationFile(
        in supportDirectory: URL = defaultSupportDirectory()
    ) -> URL? {
        let file = supportDirectory.appendingPathComponent("tmux.conf", isDirectory: false)
        do {
            try FileManager.default.createDirectory(at: supportDirectory, withIntermediateDirectories: true)
            try Data(configurationFileContents().utf8).write(to: file, options: .atomic)
            return file
        } catch {
            return nil
        }
    }

    static func defaultSupportDirectory() -> URL {
        FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Flotilla", isDirectory: true)
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
        tmuxExecutable: URL?,
        configurationFile: URL? = nil,
        environmentKeysToUnset: Set<String> = []
    ) -> (executable: URL, arguments: [String], environment: [String: String]) {
        let detectedKeysToUnset = ChildProcessEnvironment.blockedVariableNames(in: environment)
        let keysToUnset = environmentKeysToUnset.union(detectedKeysToUnset).sorted()
        let sanitizedEnvironment = ChildProcessEnvironment.sanitized(environment)
        guard let tmuxExecutable else {
            return (agentExecutable, arguments, sanitizedEnvironment)
        }
        // The `default-terminal` option is set via a separate synchronous
        // `tmux set-option -g default-terminal tmux-256color` call in
        // `SessionProcessManager.start()` before this wrapper is invoked.
        // This avoids unreliable `;` command chaining in argv.
        // `-D` (which `-A` turns into attach-session's `-d`) detaches any
        // client already on this session. tmux sizes a window to the smallest
        // attached client, so a client left behind by a previous Flotilla run
        // — or by a crash — otherwise pins the agent to that stale, usually
        // smaller size no matter how large the real terminal is.
        let configurationArguments = configurationFile.map { ["-f", $0.path] } ?? []
        var envFlags: [String] = []
        for (key, value) in sanitizedEnvironment.sorted(by: { $0.key < $1.key }) {
            guard key != "TMUX", key != "TMUX_PANE" else { continue }
            envFlags.append("-e")
            envFlags.append("\(key)=\(value)")
        }
        let wrapped = socketArguments() + configurationArguments + [
            "new-session", "-A", "-D", "-s", sessionName(for: sessionID),
            "-c", workingDirectory.path
        ] + envFlags + [
            "--"
        ] + sanitizedAgentCommand(
            executable: agentExecutable,
            arguments: arguments,
            keysToUnset: keysToUnset
        )
        var wrappedEnvironment = sanitizedEnvironment
        wrappedEnvironment.removeValue(forKey: "TMUX")
        wrappedEnvironment.removeValue(forKey: "TMUX_PANE")
        wrappedEnvironment["TERM"] = outerClientTERM
        return (tmuxExecutable, wrapped, wrappedEnvironment)
    }

    /// A tmux server keeps the environment from the client that created it.
    /// Even after Flotilla starts sending a clean client environment, an old
    /// server may still hold Xcode's injected values. `/usr/bin/env -u` makes
    /// their removal explicit in the pane immediately before the agent execs.
    private static func sanitizedAgentCommand(
        executable: URL,
        arguments: [String],
        keysToUnset: [String]
    ) -> [String] {
        guard !keysToUnset.isEmpty else {
            return [executable.path] + arguments
        }
        let unsetArguments = keysToUnset.flatMap { ["-u", $0] }
        return ["/usr/bin/env"] + unsetArguments + [executable.path] + arguments
    }
}

/// Seam for probing client dimensions and triggering client repaints on a tmux session.
protocol TmuxClientProbing: Sendable {
    /// Returns the width and height of the client attached to the named session,
    /// or nil if no client is attached or the query fails.
    func clientSize(sessionNamed name: String, tmuxExecutable: URL) -> PTYSize?

    /// Instructs tmux to repaint the client attached to the named session.
    func refreshClient(sessionNamed name: String, tmuxExecutable: URL)
}

struct ProcessTmuxClientProbe: TmuxClientProbing {
    func clientSize(sessionNamed name: String, tmuxExecutable: URL) -> PTYSize? {
        let process = ChildProcessEnvironment.makeProcess()
        process.executableURL = tmuxExecutable
        process.arguments = TmuxSessionWrapping.socketArguments() + [
            "list-clients", "-t", name, "-F", "#{client_width}x#{client_height}"
        ]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else { return nil }
            let output = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            guard let firstLine = output.components(separatedBy: .newlines).first(where: { !$0.isEmpty }) else {
                return nil
            }
            let parts = firstLine.split(separator: "x")
            guard parts.count == 2,
                  let cols = Int(parts[0]),
                  let rows = Int(parts[1]) else {
                return nil
            }
            return PTYSize(cols: cols, rows: rows)
        } catch {
            return nil
        }
    }

    func refreshClient(sessionNamed name: String, tmuxExecutable: URL) {
        let listProcess = ChildProcessEnvironment.makeProcess()
        listProcess.executableURL = tmuxExecutable
        listProcess.arguments = TmuxSessionWrapping.socketArguments() + [
            "list-clients", "-t", name, "-F", "#{client_name}"
        ]
        let pipe = Pipe()
        listProcess.standardOutput = pipe
        listProcess.standardError = FileHandle.nullDevice
        do {
            try listProcess.run()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            listProcess.waitUntilExit()
            guard listProcess.terminationStatus == 0 else { return }
            let output = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            let clientNames = output.components(separatedBy: .newlines)
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
            for clientName in clientNames {
                let refreshProc = ChildProcessEnvironment.makeProcess()
                refreshProc.executableURL = tmuxExecutable
                refreshProc.arguments = TmuxSessionWrapping.socketArguments() + [
                    "refresh-client", "-t", clientName
                ]
                refreshProc.standardOutput = FileHandle.nullDevice
                refreshProc.standardError = FileHandle.nullDevice
                if (try? refreshProc.run()) != nil {
                    refreshProc.waitUntilExit()
                }
            }
        } catch {
            return
        }
    }
}

/// Seam for explicitly destroying a session's tmux server-side state.
protocol TmuxSessionTerminating: Sendable {
    func killSession(named name: String, tmuxExecutable: URL)
    func listSessions(tmuxExecutable: URL) -> [String]
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

        let process = ChildProcessEnvironment.makeProcess()
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
        let stderr = String(decoding: errorPipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self).lowercased()
        if stderr.contains("server exited unexpectedly")
            || stderr.contains("lost server")
            || stderr.contains("protocol version mismatch") {
            return false
        }
        return true
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
        let process = ChildProcessEnvironment.makeProcess()
        process.executableURL = tmuxExecutable
        process.arguments = TmuxSessionWrapping.socketArguments() + ["kill-session", "-t", name]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        // Best-effort: a missing session (never tmux-backed, or already
        // gone) just fails silently — there's nothing to clean up either way.
        // Synchronous on purpose: callers (session restart) immediately run
        // `new-session -A` with the same name, and an in-flight kill landing
        // after that would kill the freshly created session. Only wait when
        // the process actually started — `waitUntilExit` on a process whose
        // `run()` threw blocks forever.
        if (try? process.run()) != nil {
            process.waitUntilExit()
        }
    }

    func listSessions(tmuxExecutable: URL) -> [String] {
        guard FileManager.default.fileExists(atPath: ProcessTmuxServerProbe.defaultSocketPath()) else {
            return []
        }
        let process = ChildProcessEnvironment.makeProcess()
        process.executableURL = tmuxExecutable
        process.arguments = TmuxSessionWrapping.socketArguments() + ["list-sessions", "-F", "#{session_name}"]
        let outputPipe = Pipe()
        process.standardOutput = outputPipe
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            let data = outputPipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else { return [] }
            let output = String(decoding: data, as: UTF8.self)
            return output
                .components(separatedBy: .newlines)
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
        } catch {
            return []
        }
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
        if goal.contains("\n") || goal.contains("\r") {
            pasteGoal(goal, toSessionNamed: name, tmuxExecutable: tmuxExecutable)
        } else {
            // Two separate invocations, matching the verified-working manual
            // sequence: the literal text lands in the composer, then Enter — as
            // its own distinct injection — is what actually submits it.
            runSendKeys(["-t", name, "-l", goal], tmuxExecutable: tmuxExecutable)
        }
        runSendKeys(["-t", name, "Enter"], tmuxExecutable: tmuxExecutable)
    }

    private func pasteGoal(_ goal: String, toSessionNamed name: String, tmuxExecutable: URL) {
        let bufferName = "flotilla-paste-\(UUID().uuidString)"
        let loadProcess = ChildProcessEnvironment.makeProcess()
        loadProcess.executableURL = tmuxExecutable
        loadProcess.arguments = TmuxSessionWrapping.socketArguments() + ["load-buffer", "-b", bufferName, "-"]
        let inPipe = Pipe()
        loadProcess.standardInput = inPipe
        loadProcess.standardOutput = FileHandle.nullDevice
        loadProcess.standardError = FileHandle.nullDevice
        do {
            try loadProcess.run()
            inPipe.fileHandleForWriting.write(Data(goal.utf8))
            try? inPipe.fileHandleForWriting.close()
            loadProcess.waitUntilExit()
        } catch {
            runSendKeys(["-t", name, "-l", goal], tmuxExecutable: tmuxExecutable)
            return
        }

        let pasteProcess = ChildProcessEnvironment.makeProcess()
        pasteProcess.executableURL = tmuxExecutable
        pasteProcess.arguments = TmuxSessionWrapping.socketArguments()
            + ["paste-buffer", "-p", "-d", "-b", bufferName, "-t", name]
        pasteProcess.standardOutput = FileHandle.nullDevice
        pasteProcess.standardError = FileHandle.nullDevice
        try? pasteProcess.run()
        pasteProcess.waitUntilExit()
    }

    private func waitForPaneToStabilize(sessionName: String, tmuxExecutable: URL) {
        let deadline = Date().addingTimeInterval(6)
        var previous: String?
        var stableStreak = 0
        while Date() < deadline {
            guard let current = capturePane(sessionName: sessionName, tmuxExecutable: tmuxExecutable) else {
                Thread.sleep(forTimeInterval: 0.1)
                continue
            }
            // Fast-path: active prompt indicator is ready
            if current.contains("❯") || current.contains("> ") || current.contains("cwd:")
                || current.contains("? for help") || current.contains("What would you like") {
                return
            }
            if current == previous {
                stableStreak += 1
                if stableStreak >= 3 { return } // unchanged across ~300ms
            } else {
                stableStreak = 0
            }
            previous = current
            Thread.sleep(forTimeInterval: 0.1)
        }
    }

    private func capturePane(sessionName: String, tmuxExecutable: URL) -> String? {
        guard FileManager.default.fileExists(atPath: ProcessTmuxServerProbe.defaultSocketPath()) else {
            return nil
        }
        let process = ChildProcessEnvironment.makeProcess()
        process.executableURL = tmuxExecutable
        process.arguments = TmuxSessionWrapping.socketArguments()
            + ["capture-pane", "-p", "-t", sessionName]
        let outputPipe = Pipe()
        process.standardOutput = outputPipe
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            return nil
        }

        let done = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            process.waitUntilExit()
            done.signal()
        }
        guard done.wait(timeout: .now() + 2) == .success else {
            process.terminate()
            return nil
        }

        guard process.terminationStatus == 0 else { return nil }
        let data = outputPipe.fileHandleForReading.readDataToEndOfFile()
        return String(decoding: data, as: UTF8.self)
    }

    private func runSendKeys(_ arguments: [String], tmuxExecutable: URL) {
        let process = ChildProcessEnvironment.makeProcess()
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

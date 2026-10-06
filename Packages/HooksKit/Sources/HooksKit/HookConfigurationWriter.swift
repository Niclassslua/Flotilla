import Foundation
import Darwin
import SessionKit

/// Configures provider-native lifecycle hooks for one launched session.
///
/// The protocol keeps process launch code testable without coupling it to
/// filesystem-backed configuration details.
public protocol HookConfiguring: Sendable {
    func configureHooks(
        for kind: AgentKind,
        sessionID: UUID,
        workingDirectory: URL,
        supportDirectory: URL
    ) -> Bool

    func launchArguments(for kind: AgentKind, supportDirectory: URL) -> [String]
}

/// Wires a launching agent's own event mechanism to a per-session status
/// file, so `HookEventReceiver` can read exact, structured status instead
/// of `TerminalScreenHeuristic` guessing from rendered text.
///
/// All four supported agent kinds are wired today. Every provider process
/// receives `FLOTILLA_HOOK_EVENT_FILE`, which points at that Flotilla
/// session's JSONL file. Providers whose project config is shared install a
/// single stable hook that reads this per-process value; they never bake a
/// session ID or event-file path into shared project files.
///
/// Codex uses its documented lifecycle-hook schema through inline `--config`
/// overrides and its self-describing `hook_event_name` payload.
/// `PermissionRequest` records `waitingForInput` and forwards requests to the
/// companion bridge when available; otherwise it exits silently and leaves
/// Codex's normal approval prompt in charge.
///
/// Claude Code's own config is passed via `launchArguments`'s `--settings`
/// flag rather than written into `<workingDirectory>/.claude/settings.json`
/// (the previous approach). That file is shared by every session running
/// in the same project directory (agent-managed-worktree sessions all
/// launch with `workingDirectory` set to the project root), and Claude
/// Code runs *every* hook group registered for an event whenever it fires,
/// with no per-session scoping of its own — so a shared-file entry for
/// session B fires on session A's events too, marking B `working` when it
/// did nothing. `--settings` is per-process and merges additively with the
/// project's own settings, so a session's own hook group passed this way is
/// never visible to any other process — cross-firing becomes structurally
/// impossible instead of merely mitigated.
///
/// Antigravity has no `--settings`-equivalent per-invocation flag, so its
/// hook group lives once in the user-level `~/.gemini/config/hooks.json`,
/// never in a project. The group's commands are constant and do nothing
/// without `FLOTILLA_HOOK_EVENT_FILE`, so every agy process outside Flotilla
/// runs them as no-ops and every Flotilla process routes to its own session.
///
/// OpenCode uses one stable project plugin (`flotilla-status.js`). Multiple
/// plugin files all receive the same process event stream, so per-session
/// plugin files would cross-contaminate siblings; environment-based routing
/// keeps the shared plugin constant and every write session-specific.
public struct HookConfigurationWriter: HookConfiguring {
    /// Antigravity's user-level hooks file, which every agy process reads.
    /// Injectable so tests never touch the real one.
    public let antigravityGlobalHooksFile: URL

    public init(antigravityGlobalHooksFile: URL = HookConfigurationWriter.defaultAntigravityGlobalHooksFile) {
        self.antigravityGlobalHooksFile = antigravityGlobalHooksFile
    }

    /// `~/.gemini/config/hooks.json` — verified to be read by agy 1.3.0.
    public static var defaultAntigravityGlobalHooksFile: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".gemini/config/hooks.json", isDirectory: false)
    }

    /// The key Flotilla owns in an Antigravity hooks file.
    static let antigravityHookGroupKey = "flotilla-status"

    /// Scoped to the launched provider process. Shared project hook files
    /// read this value to route an event to the correct Flotilla session.
    public static let eventFileEnvironmentKey = "FLOTILLA_HOOK_EVENT_FILE"

    /// Guards the read-modify-write into a provider's *shared* config file
    /// (Antigravity — Claude Code and Codex wiring travels via
    /// `launchArguments` and never touches a shared file). Agent-managed-
    /// worktree sessions all launch with `workingDirectory` set to the
    /// project root, so every such session in the same project shares one
    /// provider config. A process-wide lock plus a POSIX advisory file lock
    /// serializes Flotilla instances; atomic writes and fail-closed parsing
    /// protect user config.
    private static let sharedConfigFileLock = NSLock()

    /// Whether `configureHooks`/`launchArguments` can do anything useful for
    /// this agent kind. `HookCoordinator` checks this before bothering to
    /// spin up a `HookEventReceiver`.
    public static func supportsHooks(for kind: AgentKind) -> Bool {
        switch kind {
        case .claudeCode, .antigravity, .codexCLI, .openCode: return true
        // Temporary: Cursor hooks land next; keep the coordinator path open.
        case .cursorAgent: return true
        }
    }

    /// The append-only file a launched session's hook command writes one
    /// JSON line to per event, and that `HookEventReceiver` tails.
    public static func eventFilePath(for sessionID: UUID, supportDirectory: URL) -> URL {
        supportDirectory
            .appendingPathComponent("hooks", isDirectory: true)
            .appendingPathComponent("\(sessionID.uuidString).jsonl", isDirectory: false)
    }

    /// The stable wrapper script Antigravity's hooks invoke (see
    /// `configureAntigravityHooks`). Modeled on
    /// `TmuxSessionWrapping.writeConfigurationFile`'s pattern of generating a
    /// small support file into `supportDirectory` at runtime.
    private static func antigravityWrapperScriptPath(supportDirectory: URL) -> URL {
        supportDirectory
            .appendingPathComponent("hooks", isDirectory: true)
            .appendingPathComponent("flotilla-antigravity.sh", isDirectory: false)
    }

    /// Stable Cursor Agent CLI hook wrapper (see `configureCursorHooks`).
    public static func cursorWrapperScriptPath(supportDirectory: URL) -> URL {
        supportDirectory
            .appendingPathComponent("hooks", isDirectory: true)
            .appendingPathComponent("flotilla-cursor.sh", isDirectory: false)
    }

    /// The stable wrapper script Codex's hooks invoke (see
    /// `configureCodexHooks`).
    private static func codexWrapperScriptPath(supportDirectory: URL) -> URL {
        supportDirectory
            .appendingPathComponent("hooks", isDirectory: true)
            .appendingPathComponent("flotilla-codex.sh", isDirectory: false)
    }

    /// Prepares `eventFilePath` and provider support files
    /// for a fresh launch, and — for agent kinds whose wiring can't travel
    /// via `launchArguments` — merges this session's hook group into that
    /// provider's shared config file.
    ///
    /// Best-effort by design: returns `false` (does not throw) when the
    /// agent kind isn't hook-capable or a write fails, so a broken/
    /// read-only project directory never blocks a session launch — the
    /// caller falls back to `TerminalScreenHeuristic` either way.
    @discardableResult
    public func configureHooks(
        for kind: AgentKind,
        sessionID: UUID,
        workingDirectory: URL,
        supportDirectory: URL
    ) -> Bool {
        guard Self.supportsHooks(for: kind) else { return false }

        let eventFile = Self.eventFilePath(for: sessionID, supportDirectory: supportDirectory)
        do {
            try FileManager.default.createDirectory(
                at: eventFile.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            // Truncate any stale content from a previous launch of this
            // session ID before the new process starts appending to it.
            try Data().write(to: eventFile, options: .atomic)
        } catch {
            return false
        }

        switch kind {
        case .claudeCode:
            Self.removeLegacyClaudeHookGroups(in: workingDirectory)
            try? Data().write(
                to: Self.displayFilePath(for: sessionID, supportDirectory: supportDirectory),
                options: .atomic
            )
            return true
        case .antigravity:
            return Self.configureAntigravityHooks(
                workingDirectory: workingDirectory,
                supportDirectory: supportDirectory,
                globalHooksFile: antigravityGlobalHooksFile
            )
        case .codexCLI:
            return Self.configureCodexHooks(supportDirectory: supportDirectory)
        case .openCode:
            return Self.configureOpenCodeHooks(
                workingDirectory: workingDirectory
            )
        case .cursorAgent:
            return Self.configureCursorHooks(
                workingDirectory: workingDirectory,
                supportDirectory: supportDirectory
            )
        }
    }

    /// Extra CLI arguments the launched process needs so its own hook
    /// wiring travels with it, rather than being written to a file other
    /// sessions could also read. Empty for an agent kind `supportsHooks`
    /// doesn't recognize, or for a kind (Antigravity) whose wiring instead
    /// goes through `configureHooks`'s shared-file write.
    ///
    /// For Claude Code: a `--settings '<json>'` flag carrying only this
    /// session's own lifecycle and interactive hook groups, each
    /// running a shell one-liner that forwards the hook's own JSON stdin —
    /// which already carries `hook_event_name` — into `eventFilePath`.
    /// Claude Code merges `--settings` additively with the project's own
    /// `.claude/settings.json` rather than replacing it, so nothing a user
    /// or another tool configured there is disturbed.
    ///
    /// For Codex: enables the stable hooks feature and supplies four inline
    /// hook groups. The command path is TOML-encoded and remains constant
    /// across sessions, while the destination stays process-scoped in the
    /// environment.
    public func launchArguments(for kind: AgentKind, supportDirectory: URL) -> [String] {
        Self.launchArguments(for: kind, supportDirectory: supportDirectory)
    }

    public static func launchArguments(for kind: AgentKind, supportDirectory: URL) -> [String] {
        guard supportsHooks(for: kind) else { return [] }

        switch kind {
        case .claudeCode:
            let command = eventForwardingShellCommand()
            // Observe-only groups run `async`: Claude starts them in the
            // background and never waits, so recording an event cannot slow
            // the turn. Measured on 2.1.291, async lines still land in the
            // order Claude fired them. `PermissionRequest` alone must stay
            // synchronous — its stdout is the phone's decision.
            let hookGroup: [String: Any] = [
                "hooks": [
                    ["type": "command", "command": command, "async": true]
                ]
            ]
            // One event per streamed chunk of assistant text, so it goes to a
            // sibling file instead of the status stream `HookEventReceiver`
            // tails; only the companion's live transcript reads it.
            let displayGroup: [String: Any] = [
                "hooks": [
                    ["type": "command", "command": eventForwardingShellCommand(suffix: Self.displayFileSuffix), "async": true]
                ]
            ]
            // The phone answers Claude's dialogs through this hook. The
            // timeout is a day because a held request waits for a person;
            // the terminal dialog stays live and first answer wins.
            let permissionHookGroup: [String: Any] = [
                "hooks": [
                    [
                        "type": "command",
                        "command": companionBridgeShellCommand(socketPath: companionSocketPath(supportDirectory: supportDirectory)),
                        "timeout": 86_400
                    ]
                ]
            ]
            let interactiveHookGroup: [String: Any] = [
                "matcher": "AskUserQuestion|ExitPlanMode",
                "hooks": [
                    ["type": "command", "command": command, "async": true]
                ]
            ]
            var hooks: [String: Any] = [
                "PreToolUse": [interactiveHookGroup],
                "PermissionRequest": [permissionHookGroup],
                "MessageDisplay": [displayGroup]
            ]
            for event in claudeObservedEvents {
                hooks[event] = [hookGroup]
            }
            let settings: [String: Any] = ["hooks": hooks]
            guard let data = try? JSONSerialization.data(withJSONObject: settings, options: [.sortedKeys]),
                  let json = String(data: data, encoding: .utf8) else {
                return []
            }
            return ["--settings", json]
        case .codexCLI:
            let scriptPath = codexWrapperScriptPath(supportDirectory: supportDirectory)
            let commandLiteral = tomlStringLiteral(quoted(scriptPath.path))
            let hookGroup = "[{matcher=\"\",hooks=[{type=\"command\",command=\(commandLiteral)}]}]"
            return [
                "--config", "features.hooks=true",
                "--config", "hooks.PreToolUse=\(hookGroup)",
                "--config", "hooks.PermissionRequest=[{matcher=\"\",hooks=[{type=\"command\",command=\(tomlStringLiteral(quoted(scriptPath.path) + " PermissionRequest")),timeout=86400}]}]",
                "--config", "hooks.PostToolUse=\(hookGroup)",
                "--config", "hooks.Stop=\(hookGroup)"
            ]
        case .openCode, .antigravity, .cursorAgent:
            return []
        }
    }

    /// Claude Code events recorded verbatim into the status stream, each by
    /// an async observe-only hook. `PreToolUse` (matched to the interactive
    /// tools), `PermissionRequest` (the phone's decision) and
    /// `MessageDisplay` (the display file) are registered separately.
    /// `SubagentStop` and `SessionEnd` are left out on purpose: Claude's own
    /// background helpers emit `SubagentStop` after the turn's `Stop`, and
    /// neither says anything about the session's status.
    static let claudeObservedEvents = [
        "SessionStart", "UserPromptSubmit",
        "PostToolUse", "PostToolUseFailure", "PermissionDenied",
        "Notification", "Stop", "StopFailure",
        "PreCompact", "PostCompact", "SubagentStart",
    ]

    /// Suffix of the sibling file Claude's `MessageDisplay` deltas go to.
    public static let displayFileSuffix = ".display"

    /// Where a session's streamed assistant text is recorded, next to its
    /// event file. Truncated with it on launch and removed with it on delete.
    public static func displayFilePath(for sessionID: UUID, supportDirectory: URL) -> URL {
        URL(fileURLWithPath: eventFilePath(for: sessionID, supportDirectory: supportDirectory).path + displayFileSuffix)
    }

    /// Appends self-describing hook stdin JSON verbatim plus a trailing
    /// newline. Claude and Codex send one compact object per invocation with
    /// no terminator, so the newline keeps the file line-delimited.
    ///
    /// The JSON and its newline go out in one `printf` so that concurrently
    /// running async hooks cannot interleave one line's newline into another.
    private static func eventForwardingShellCommand(suffix: String = "") -> String {
        return #"event_file="${FLOTILLA_HOOK_EVENT_FILE:-}"; [ -n "$event_file" ] || exit 0; input=$(cat); printf '%s\n' "$input" >> "$event_file"# + suffix + #"""#
    }

    /// The Unix socket the iPhone companion's permission bridge listens on
    /// while the companion link is enabled.
    public static func companionSocketPath(supportDirectory: URL) -> URL {
        supportDirectory.appendingPathComponent("companion.sock", isDirectory: false)
    }

    /// Records the event exactly like `eventForwardingShellCommand`, then —
    /// only when the companion socket exists — hands the request to Flotilla
    /// and prints whatever decision comes back.
    ///
    /// Fail-open by construction: no socket, a stale socket, or a bridge that
    /// closes without answering all print nothing and exit 0, which leaves
    /// Claude's own terminal dialog in charge.
    static func companionBridgeShellCommand(socketPath: URL) -> String {
        let socket = quoted(socketPath.path)
        return #"input=$(cat); event_file="${FLOTILLA_HOOK_EVENT_FILE:-}"; [ -n "$event_file" ] || exit 0; printf '%s\n' "$input" >> "$event_file"; "# +
            #"[ -S \#(socket) ] || exit 0; printf '%s\n%s\n' "$event_file" "$input" | /usr/bin/nc -U \#(socket) 2>/dev/null; exit 0"#
    }

    // MARK: - Antigravity

    /// Writes the stable wrapper script and replaces Flotilla's hook group in
    /// Antigravity's user-level hooks file; removes the group older releases
    /// wrote into `<workingDirectory>/.agents/hooks.json`.
    ///
    /// Antigravity's payload names no event (2026-09 and 1.3.0), so each
    /// command passes it as `<wrapper> <EventName>` and the wrapper writes a
    /// self-describing `{"event","payload"}` line. The wrapper prints
    /// nothing for `PreToolUse`: agy 1.3.0 treats a silent hook exactly like
    /// no hook, and probes showed an `allow` (even with `permissionOverrides`)
    /// never skips its own confirmation picker — only `deny` takes effect —
    /// so a hook cannot answer approvals and must not pretend to decide.
    ///
    /// `PreInvocation` marks the turn working and is where prompts the
    /// companion queued mid-turn are injected (`injectSteps`), before the
    /// next model call. `PreToolUse`/`PostToolUse` (matcher `*`) and `Stop`
    /// drive the rest; `HookEventReceiver` reads `toolCall.name`,
    /// `ArtifactMetadata.RequestFeedback` and `fullyIdle`. Tool and file
    /// approval dialogs stay invisible to every hook and are read off the
    /// screen and the `--log-file`.
    private static func configureAntigravityHooks(
        workingDirectory: URL,
        supportDirectory: URL,
        globalHooksFile: URL
    ) -> Bool {
        let scriptPath = antigravityWrapperScriptPath(supportDirectory: supportDirectory)
        do {
            try FileManager.default.createDirectory(
                at: scriptPath.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try Data(antigravityWrapperScriptContents.utf8).write(to: scriptPath, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: scriptPath.path)
        } catch {
            return false
        }

        do {
            try withSharedConfigLock(supportDirectory: supportDirectory) {
                var root = try loadJSONObject(at: globalHooksFile)
                root[antigravityHookGroupKey] = antigravityHookGroup
                try writeJSONObject(root, to: globalHooksFile, creating: globalHooksFile.deletingLastPathComponent())
            }
        } catch {
            return false
        }
        // Best-effort: a project file Flotilla can't clean must not stop the
        // launch. Until it is cleaned, agy runs the old group's commands too,
        // which only record — the wrapper is the same script.
        try? withSharedConfigLock(supportDirectory: supportDirectory) {
            removeLegacyAntigravityProjectHooks(in: workingDirectory)
        }
        return true
    }

    /// One command per event, the same for every session and every Flotilla
    /// install: it finds the wrapper next to the session's event file, so the
    /// global file never names a support directory and is inert outside
    /// Flotilla.
    static var antigravityHookGroup: [String: Any] {
        let command: (String) -> [String: Any] = { event in
            [
                "type": "command",
                "command": #"event_file="${FLOTILLA_HOOK_EVENT_FILE:-}"; [ -n "$event_file" ] || exit 0; wrapper="$(dirname "$event_file")/flotilla-antigravity.sh"; [ -x "$wrapper" ] || exit 0; exec "$wrapper" "# + event,
                "timeout": 10
            ]
        }
        return [
            "PreToolUse": [["matcher": "*", "hooks": [command("PreToolUse")]]],
            "PostToolUse": [["matcher": "*", "hooks": [command("PostToolUse")]]],
            "PreInvocation": [command("PreInvocation")],
            "Stop": [command("Stop")]
        ]
    }

    /// Records the event; on `PreInvocation`, hands over prompts the
    /// companion queued next to the event file. Moving the queue first keeps
    /// a prompt queued during delivery for the next invocation.
    static let antigravityWrapperScriptContents = """
    #!/bin/sh
    event="$1"
    payload="$(cat)"
    event_file="${FLOTILLA_HOOK_EVENT_FILE:-}"
    [ -n "$event_file" ] || exit 0
    printf '{"event":"%s","payload":%s}\\n' "$event" "$payload" >> "$event_file"
    if [ "$event" = "PreInvocation" ] && [ -f "$event_file.queue" ]; then
        queue="$event_file.queue.$$"
        mv "$event_file.queue" "$queue" 2>/dev/null && cat "$queue" && rm -f "$queue"
    fi
    exit 0
    """

    /// Drops the `flotilla-status` group from a project's `.agents/hooks.json`
    /// (written there before the hooks moved to the user-level file), and
    /// the file itself when that group was all it held. Malformed or
    /// unfamiliar JSON is left byte-for-byte untouched.
    static func removeLegacyAntigravityProjectHooks(in workingDirectory: URL) {
        let configFile = workingDirectory.appendingPathComponent(".agents/hooks.json", isDirectory: false)
        guard var root = try? loadJSONObject(at: configFile),
              root.removeValue(forKey: antigravityHookGroupKey) != nil else { return }
        if root.isEmpty {
            try? FileManager.default.removeItem(at: configFile)
        } else {
            try? writeJSONObject(root, to: configFile, creating: configFile.deletingLastPathComponent())
        }
    }

    private static func quoted(_ path: String) -> String {
        "'\(path.replacingOccurrences(of: "'", with: "'\\''"))'"
    }

    private static func tomlStringLiteral(_ value: String) -> String {
        guard let data = try? JSONSerialization.data(
            withJSONObject: value,
            options: [.fragmentsAllowed, .withoutEscapingSlashes]
        ), let encoded = String(data: data, encoding: .utf8) else {
            return "\"\""
        }
        return encoded
    }

    private enum ConfigurationError: Error {
        case invalidJSONObject(URL)
        case lockUnavailable(URL)
    }

    /// Serializes Flotilla's read-modify-write across app processes. The
    /// provider itself and external editors do not honor this lock, so the
    /// final write remains atomic and malformed/intermediate JSON fails
    /// closed rather than being replaced.
    private static func withSharedConfigLock<T>(
        supportDirectory: URL,
        operation: () throws -> T
    ) throws -> T {
        sharedConfigFileLock.lock()
        defer { sharedConfigFileLock.unlock() }

        let hooksDirectory = supportDirectory.appendingPathComponent("hooks", isDirectory: true)
        try FileManager.default.createDirectory(at: hooksDirectory, withIntermediateDirectories: true)
        let lockFile = hooksDirectory.appendingPathComponent("shared-config.lock")
        if !FileManager.default.fileExists(atPath: lockFile.path),
           !FileManager.default.createFile(atPath: lockFile.path, contents: nil) {
            throw ConfigurationError.lockUnavailable(lockFile)
        }

        let handle = try FileHandle(forUpdating: lockFile)
        defer { try? handle.close() }
        guard Darwin.lockf(handle.fileDescriptor, F_LOCK, 0) == 0 else {
            throw ConfigurationError.lockUnavailable(lockFile)
        }
        defer { _ = Darwin.lockf(handle.fileDescriptor, F_ULOCK, 0) }
        return try operation()
    }

    private static func loadJSONObject(at file: URL) throws -> [String: Any] {
        guard FileManager.default.fileExists(atPath: file.path) else { return [:] }
        let data = try Data(contentsOf: file)
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ConfigurationError.invalidJSONObject(file)
        }
        return object
    }

    private static func writeJSONObject(
        _ object: [String: Any],
        to file: URL,
        creating directory: URL
    ) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let data = try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: file, options: .atomic)
    }

    // MARK: - Codex CLI

    /// Writes the stable wrapper script. Hook groups travel via per-launch
    /// `--config` overrides, so Codex never modifies the project.
    ///
    /// `PostToolUse` maps to working, `Stop` to ready, and
    /// `PermissionRequest` to waiting. The wrapper records Codex's own JSON
    /// and forwards approval requests to the companion socket. A provider
    /// envelope keeps Claude-only decision fields out of Codex responses.
    private static func configureCodexHooks(
        supportDirectory: URL
    ) -> Bool {
        let scriptPath = codexWrapperScriptPath(supportDirectory: supportDirectory)
        do {
            try FileManager.default.createDirectory(
                at: scriptPath.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let socket = quoted(companionSocketPath(supportDirectory: supportDirectory).path)
            let contents = #"input=$(cat); event_file="${FLOTILLA_HOOK_EVENT_FILE:-}"; [ -n "$event_file" ] || exit 0; printf '%s\n' "$input" >> "$event_file"; "# +
                #"[ "$1" = PermissionRequest ] || exit 0; [ "${FLOTILLA_CODEX_REMOTE:-}" = 1 ] && exit 0; [ -S \#(socket) ] || exit 0; printf '%s\n{"flotilla_provider":"codex","request":%s}\n' "$event_file" "$input" | /usr/bin/nc -U \#(socket) 2>/dev/null; exit 0"# + "\n"
            try Data(contents.utf8).write(to: scriptPath, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: scriptPath.path)
        } catch {
            return false
        }

        return true
    }

    // MARK: - OpenCode

    /// The stable project plugin. Its destination comes from the launched
    /// process environment, not from project-shared source code.
    private static func openCodePluginPath(workingDirectory: URL) -> URL {
        workingDirectory
            .appendingPathComponent(".opencode/plugins", isDirectory: true)
            .appendingPathComponent("flotilla-status.js", isDirectory: false)
    }

    /// Writes (fully overwrites — no merge, no lock) the stable plugin file.
    /// `tool.execute.after` → working
    /// and `session.idle` → ready are live-verified; `permission.asked`/
    /// `question.asked` → waitingForInput with distinct reasons are wired on
    /// the strength of
    /// every other event name from the same source checking out live, not
    /// directly observed themselves.
    private static func configureOpenCodeHooks(
        workingDirectory: URL
    ) -> Bool {
        let pluginPath = openCodePluginPath(workingDirectory: workingDirectory)
        do {
            try FileManager.default.createDirectory(
                at: pluginPath.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try Data(openCodePluginContents().utf8).write(to: pluginPath, options: .atomic)
            try removeLegacyOpenCodePlugins(in: pluginPath.deletingLastPathComponent())
            return true
        } catch {
            return false
        }
    }

    private static func openCodePluginContents() -> String {
        return """
        import fs from "node:fs";
        const eventFile = process.env.FLOTILLA_HOOK_EVENT_FILE;
        function append(event) {
          if (!eventFile) return;
          try { fs.appendFileSync(eventFile, JSON.stringify({ event }) + "\\n"); } catch {}
        }
        export const FlotillaStatus = async () => {
          return {
            "tool.execute.after": async () => { append("tool.execute.after"); },
            event: async ({ event }) => {
              if (event.type === "session.idle" || event.type === "permission.asked" || event.type === "question.asked") {
                append(event.type);
              }
            },
          };
        };
        """
    }

    private static func removeLegacyOpenCodePlugins(in directory: URL) throws {
        let names = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        for name in names where name.hasPrefix("flotilla-status-") && name.hasSuffix(".js") {
            // Concurrent launches can both discover the same legacy file.
            // Whichever removes it first wins; absence is already success.
            try? FileManager.default.removeItem(at: directory.appendingPathComponent(name))
        }
    }

    // MARK: - Cursor Agent CLI

    /// Writes the stable wrapper and merges Flotilla's Cursor hooks into
    /// `<workingDirectory>/.cursor/hooks.json` without wiping other tools'
    /// entries (CodeIsland, Xirp, …).
    ///
    /// Every hook only records the event; none decides. A hook `allow` does
    /// not skip Cursor's own approval dialog, and nothing on the Mac answers a
    /// held hook, so the phone mirrors Cursor's dialog instead
    /// (`CursorCompanionAdapter`).
    private static func configureCursorHooks(
        workingDirectory: URL,
        supportDirectory: URL
    ) -> Bool {
        let scriptPath = cursorWrapperScriptPath(supportDirectory: supportDirectory)
        do {
            try FileManager.default.createDirectory(
                at: scriptPath.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try Data(cursorWrapperScriptContents.utf8).write(to: scriptPath, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: scriptPath.path)
            // The socket client earlier versions wrote beside the wrapper.
            try? FileManager.default.removeItem(
                at: scriptPath.deletingLastPathComponent()
                    .appendingPathComponent("flotilla-cursor-bridge.py", isDirectory: false)
            )
        } catch {
            return false
        }

        let configDirectory = workingDirectory.appendingPathComponent(".cursor", isDirectory: true)
        let configFile = configDirectory.appendingPathComponent("hooks.json", isDirectory: false)
        let observeHook: [String: Any] = [
            "command": quoted(scriptPath.path),
            "timeout": 30
        ]

        do {
            try withSharedConfigLock(supportDirectory: supportDirectory) {
                var root = try loadJSONObject(at: configFile)
                root["version"] = root["version"] ?? 1
                var hooks = root["hooks"] as? [String: Any] ?? [:]

                func replaceFlotillaEntries(in existing: Any?, with entry: [String: Any]) -> [[String: Any]] {
                    let list = existing as? [[String: Any]] ?? []
                    let kept = list.filter { item in
                        guard let cmd = item["command"] as? String else { return true }
                        return !cmd.contains("flotilla-cursor.sh")
                    }
                    return kept + [entry]
                }

                for event in cursorHookEvents {
                    hooks[event] = replaceFlotillaEntries(in: hooks[event], with: observeHook)
                }
                root["hooks"] = hooks
                try writeJSONObject(root, to: configFile, creating: configDirectory)
            }
            return true
        } catch {
            return false
        }
    }

    static let cursorHookEvents = [
        "beforeSubmitPrompt",
        "preToolUse", "beforeShellExecution", "beforeMCPExecution",
        "postToolUse", "afterShellExecution", "afterFileEdit",
        "afterAgentResponse", "sessionEnd", "stop",
    ]

    /// Cursor hooks.json only takes a command string, so the script reads
    /// `hook_event_name` from stdin and falls back to the first argv token.
    /// It prints nothing: an empty answer leaves every decision to Cursor.
    private static let cursorWrapperScriptContents = """
    #!/bin/sh
    payload="$(cat)"
    event_file="${FLOTILLA_HOOK_EVENT_FILE:-}"
    [ -n "$event_file" ] || exit 0
    event="$(printf '%s' "$payload" | /usr/bin/python3 -c 'import sys,json; d=json.load(sys.stdin); print(d.get("hook_event_name") or "")' 2>/dev/null || true)"
    if [ -z "$event" ]; then event="${1:-unknown}"; fi
    printf '{"flotilla_provider":"cursor","hook_event_name":"%s","payload":%s}\\n' "$event" "$payload" >> "$event_file"
    exit 0
    """

    // MARK: - Legacy Claude Cleanup

    /// Checks if a shell command string matches the pre-cf38d57 Flotilla hook command
    /// that pointed directly to a fixed `<supportDirectory>/hooks/<UUID>.jsonl` file.
    public static func isLegacyClaudeHookCommand(_ command: String) -> Bool {
        guard !command.contains(eventFileEnvironmentKey) else { return false }
        guard command.contains("cat >>") else { return false }
        guard command.contains("/hooks/") else { return false }
        let uuidPattern = #"[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}\.jsonl"#
        return command.range(of: uuidPattern, options: .regularExpression) != nil
    }

    /// Filters out legacy Flotilla hook commands from a single hook group.
    /// Returns `nil` if all hook entries in the group were legacy commands and the group is now empty.
    public static func cleanedClaudeHookGroup(_ group: [String: Any]) -> [String: Any]? {
        guard let entries = group["hooks"] as? [[String: Any]] else { return group }
        let remaining = entries.filter { entry in
            guard let command = entry["command"] as? String else { return true }
            return !isLegacyClaudeHookCommand(command)
        }
        if remaining.isEmpty {
            return nil
        }
        var updated = group
        updated["hooks"] = remaining
        return updated
    }

    /// Removes fixed-path Flotilla hook groups from `<workingDirectory>/.claude/settings.json`.
    ///
    /// Preserves any other settings keys, any hook for other events, and any hook using `FLOTILLA_HOOK_EVENT_FILE`.
    /// Returns `true` if any legacy hook groups were removed and the settings file was updated.
    @discardableResult
    public static func removeLegacyClaudeHookGroups(in workingDirectory: URL) -> Bool {
        let settingsFile = workingDirectory
            .appendingPathComponent(".claude", isDirectory: true)
            .appendingPathComponent("settings.json", isDirectory: false)
        guard FileManager.default.fileExists(atPath: settingsFile.path) else { return false }

        sharedConfigFileLock.lock()
        defer { sharedConfigFileLock.unlock() }

        guard let data = try? Data(contentsOf: settingsFile),
              var settings = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let hooks = settings["hooks"] as? [String: Any] else {
            return false
        }

        var changed = false
        var updatedHooks = hooks

        for (event, value) in hooks {
            guard let groups = value as? [[String: Any]] else { continue }
            let filteredGroups = groups.compactMap(cleanedClaudeHookGroup)
            if filteredGroups.count != groups.count {
                changed = true
                if filteredGroups.isEmpty {
                    updatedHooks.removeValue(forKey: event)
                } else {
                    updatedHooks[event] = filteredGroups
                }
            }
        }

        guard changed else { return false }

        if updatedHooks.isEmpty {
            settings.removeValue(forKey: "hooks")
        } else {
            settings["hooks"] = updatedHooks
        }

        do {
            let updatedData = try JSONSerialization.data(withJSONObject: settings, options: [.prettyPrinted, .sortedKeys])
            try updatedData.write(to: settingsFile, options: .atomic)
            return true
        } catch {
            return false
        }
    }
}

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
/// stable wrapper is registered in shared `<workingDirectory>/.agents/hooks.json`.
/// The wrapper routes through the per-process event-file value, eliminating
/// sibling-session cross-firing without needing a conversation ID. It still
/// emits Antigravity's required allow response for `PreToolUse`.
///
/// OpenCode uses one stable project plugin (`flotilla-status.js`). Multiple
/// plugin files all receive the same process event stream, so per-session
/// plugin files would cross-contaminate siblings; environment-based routing
/// keeps the shared plugin constant and every write session-specific.
public struct HookConfigurationWriter: HookConfiguring {
    public init() {}

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
            return true
        case .antigravity:
            return Self.configureAntigravityHooks(
                workingDirectory: workingDirectory,
                supportDirectory: supportDirectory
            )
        case .codexCLI:
            return Self.configureCodexHooks(supportDirectory: supportDirectory)
        case .openCode:
            return Self.configureOpenCodeHooks(
                workingDirectory: workingDirectory
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
            let hookGroup: [String: Any] = [
                "hooks": [
                    ["type": "command", "command": command]
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
                    ["type": "command", "command": command]
                ]
            ]
            let settings: [String: Any] = [
                "hooks": [
                    "Notification": [hookGroup],
                    "PreToolUse": [interactiveHookGroup],
                    "PermissionRequest": [permissionHookGroup],
                    "Stop": [hookGroup],
                    "PostToolUse": [hookGroup]
                ]
            ]
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
        case .openCode, .antigravity:
            return []
        }
    }

    /// Appends self-describing hook stdin JSON verbatim plus a trailing
    /// newline. Claude and Codex send one compact object per invocation with
    /// no terminator, so the newline keeps the file line-delimited.
    private static func eventForwardingShellCommand() -> String {
        return #"event_file="${FLOTILLA_HOOK_EVENT_FILE:-}"; [ -n "$event_file" ] || exit 0; cat >> "$event_file" && printf '\n' >> "$event_file""#
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
    /// `<workingDirectory>/.agents/hooks.json`.
    ///
    /// Two things Antigravity needs that Claude Code doesn't, both handled
    /// by the wrapper script rather than a bare `cat >>` one-liner:
    ///
    /// 1. Antigravity's hook payload has no `hook_event_name`-equivalent
    ///    field, so the script is invoked as `<script> <EventName>` (the
    ///    event name is baked into the `hooks.json` command per-event, not
    ///    read from stdin) and synthesizes a self-describing JSON line
    ///    itself before appending it — `HookEventReceiver` can then treat
    ///    every provider's event file as "one self-describing JSON object
    ///    per line" uniformly.
    /// 2. `PreToolUse`'s stdout is interpreted as a live permission
    ///    decision (unlike Claude Code, where a silent exit 0 is fine) — the
    ///    script must also print `{"decision":"allow"}` for that event, or
    ///    Antigravity may hang waiting for a decision that never comes.
    ///
    /// `PreToolUse`/`PostToolUse` (matcher `*`, catching every tool call)
    /// and `Stop` drive status; `PostInvocation` only delivers prompts the
    /// companion queued mid-turn. `HookEventReceiver` decides `working` vs.
    /// `waitingForInput` for `PreToolUse` by inspecting the real payload's
    /// `toolCall.name` (`"ask_question"` is Antigravity's own tool for
    /// asking the user something, free-text or multi-choice — there is no
    /// separate permission-prompt event; tool/file approval dialogs are
    /// confirmed invisible to every hook Antigravity exposes and stay on
    /// `TerminalScreenHeuristic` permanently for this provider). `Stop` only
    /// means `ready` when its own `fullyIdle` field is `true` — `false`
    /// means an async tool call (e.g. a long-running shell command) is
    /// still outstanding and no status change should happen yet.
    ///
    /// A `planFinished`-shaped signal — `PostToolUse` where
    /// `toolCall.name == "write_to_file"` and
    /// `args.ArtifactMetadata.RequestFeedback == true` — is classified as a
    /// plan waiting for approval by `HookEventReceiver`.
    private static func configureAntigravityHooks(
        workingDirectory: URL,
        supportDirectory: URL
    ) -> Bool {
        let scriptPath = antigravityWrapperScriptPath(supportDirectory: supportDirectory)
        do {
            try FileManager.default.createDirectory(
                at: scriptPath.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            // The companion queues prompts sent mid-turn next to the event
            // file; `PostInvocation` hands them to the agent as
            // `injectSteps`. Moving the file first keeps a prompt queued
            // during delivery for the next invocation.
            let contents = wrapperScriptContents(decisionRequiredFor: ["PreToolUse"]) + """
            \nif [ "$event" = "PostInvocation" ] && [ -n "$event_file" ] && [ -f "$event_file.queue" ]; then
                queue="$event_file.queue.$$"
                mv "$event_file.queue" "$queue" 2>/dev/null && cat "$queue" && rm -f "$queue"
            fi
            """
            try Data(contents.utf8).write(to: scriptPath, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: scriptPath.path)
        } catch {
            return false
        }

        let configDirectory = workingDirectory.appendingPathComponent(".agents", isDirectory: true)
        let configFile = configDirectory.appendingPathComponent("hooks.json", isDirectory: false)

        do {
            try withSharedConfigLock(supportDirectory: supportDirectory) {
                var root = try loadJSONObject(at: configFile)
                let hookCommand: (String) -> [String: Any] = { event in
                    [
                        "type": "command",
                        "command": "\(Self.quoted(scriptPath.path)) \(event)",
                        "timeout": 10
                    ]
                }
                root["flotilla-status"] = [
                    "PreToolUse": [["matcher": "*", "hooks": [hookCommand("PreToolUse")]]],
                    "PostToolUse": [["matcher": "*", "hooks": [hookCommand("PostToolUse")]]],
                    "Stop": [hookCommand("Stop")],
                    "PostInvocation": [hookCommand("PostInvocation")]
                ]
                try writeJSONObject(root, to: configFile, creating: configDirectory)
            }
            return true
        } catch {
            return false
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

    /// Shared by every provider whose payload doesn't self-describe its own
    /// event name: the script is invoked as `<script> <EventName>` (baked
    /// into the config's command per-event, not read from stdin) and
    /// synthesizes a self-describing JSON line before appending it, so
    /// `HookEventReceiver` can treat every such provider's event file
    /// uniformly as "one self-describing JSON object per line".
    ///
    /// `decisionRequiredFor` names the events whose stdout the launching
    /// CLI reads as a live allow/deny decision rather than ignoring —
    /// getting this wrong (omitting an event that needs it) risks hanging
    /// or silently blocking the CLI, so it's only ever populated for events
    /// this has actually been confirmed to require it for (see call sites).
    private static func wrapperScriptContents(decisionRequiredFor: Set<String>) -> String {
        var script = """
        #!/bin/sh
        event="$1"
        payload="$(cat)"
        event_file="${FLOTILLA_HOOK_EVENT_FILE:-}"
        if [ -n "$event_file" ]; then
            printf '{"event":"%s","payload":%s}\\n' "$event" "$payload" >> "$event_file"
        fi
        """
        for event in decisionRequiredFor.sorted() {
            script += """
            \nif [ "$event" = "\(event)" ]; then
                printf '{"decision":"allow"}\\n'
            fi
            """
        }
        return script
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

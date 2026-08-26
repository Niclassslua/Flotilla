import Foundation
import SessionKit

/// Wires a launching agent's own event mechanism to a per-session status
/// file, so `HookEventReceiver` can read exact, structured status instead
/// of `TerminalScreenHeuristic` guessing from rendered text.
///
/// Claude Code, Antigravity, and Codex CLI are wired today. OpenCode falls
/// back to `TerminalScreenHeuristic` permanently for now — this is not a
/// temporary gap to be filled in later, it's tracked as separate,
/// per-provider follow-up work.
///
/// Codex's wiring in particular carries two assumptions never verified
/// against a real Codex session (no `codex` binary was available while this
/// was written): that `.codex/hooks.json`'s schema is Claude-Code-shaped
/// (event key → array of `{matcher, hooks: [{type, command}]}` groups), and
/// — since the wrapper script synthesizes its own self-describing event
/// line regardless — that Codex's `PostToolUse`/`Stop` actually fire that
/// often and mean what Claude Code's do. Deliberately *not* wired: Codex's
/// `PermissionRequest`, even though it's documented as the provider's
/// advantage over Antigravity for permission-prompt detection. Real-world
/// evidence (a third-party tool's source comments) describes Claude Code's
/// and Codex's `PermissionRequest` as *decision-blocking* — the same shape
/// as Antigravity's `PreToolUse`, which required answering
/// `{"decision":"allow"}` to avoid hanging the CLI. Guessing that response
/// contract wrong for Codex risks actively breaking a real user's session
/// (a hang, or a silently-denied action) rather than just producing an
/// inaccurate status — a materially worse failure mode than staying on
/// `TerminalScreenHeuristic`, so it stays there until live-verified.
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
/// wiring still goes through a shared `<workingDirectory>/.agents/hooks.json`
/// — the same cross-session-contamination shape Claude Code's old approach
/// had, mitigated the same way (session-marker-based idempotent replace
/// under a lock) but not eliminated. Antigravity's own payload carries a
/// `conversationId` that could filter this out properly, but Flotilla
/// doesn't know a fresh session's `conversationId` until its first event
/// arrives — closing this gap is tracked as follow-up work, not solved here.
public struct HookConfigurationWriter: Sendable {
    public init() {}

    /// Guards the read-modify-write into a provider's *shared* config file
    /// (only Antigravity today — Claude Code's own wiring travels via
    /// `launchArguments` and never touches a shared file). Agent-managed-
    /// worktree sessions all launch with `workingDirectory` set to the
    /// project root, so every such session in the same project shares one
    /// `.agents/hooks.json`. One process-wide lock is enough: the critical
    /// section is a small synchronous file write, and nothing outside this
    /// type touches the file.
    private static let sharedConfigFileLock = NSLock()

    /// Whether `configureHooks`/`launchArguments` can do anything useful for
    /// this agent kind. `HookCoordinator` checks this before bothering to
    /// spin up a `HookEventReceiver`.
    public static func supportsHooks(for kind: AgentKind) -> Bool {
        switch kind {
        case .claudeCode, .antigravity, .codexCLI: return true
        case .openCode: return false
        }
    }

    /// The append-only file a launched session's hook command writes one
    /// JSON line to per event, and that `HookEventReceiver` tails.
    public static func eventFilePath(for sessionID: UUID, supportDirectory: URL) -> URL {
        supportDirectory
            .appendingPathComponent("hooks", isDirectory: true)
            .appendingPathComponent("\(sessionID.uuidString).jsonl", isDirectory: false)
    }

    /// The per-session wrapper script Antigravity's hooks invoke (see
    /// `configureAntigravityHooks`). Modeled on
    /// `TmuxSessionWrapping.writeConfigurationFile`'s pattern of generating a
    /// small support file into `supportDirectory` at runtime.
    private static func antigravityWrapperScriptPath(for sessionID: UUID, supportDirectory: URL) -> URL {
        supportDirectory
            .appendingPathComponent("hooks", isDirectory: true)
            .appendingPathComponent("\(sessionID.uuidString)-antigravity.sh", isDirectory: false)
    }

    /// The per-session wrapper script Codex's hooks invoke (see
    /// `configureCodexHooks`).
    private static func codexWrapperScriptPath(for sessionID: UUID, supportDirectory: URL) -> URL {
        supportDirectory
            .appendingPathComponent("hooks", isDirectory: true)
            .appendingPathComponent("\(sessionID.uuidString)-codex.sh", isDirectory: false)
    }

    /// Prepares `eventFilePath` (and, for Antigravity, its wrapper script)
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
            return true
        case .antigravity:
            return Self.configureAntigravityHooks(
                sessionID: sessionID,
                workingDirectory: workingDirectory,
                supportDirectory: supportDirectory,
                eventFile: eventFile
            )
        case .codexCLI:
            return Self.configureCodexHooks(
                sessionID: sessionID,
                workingDirectory: workingDirectory,
                supportDirectory: supportDirectory,
                eventFile: eventFile
            )
        case .openCode:
            return false
        }
    }

    /// Extra CLI arguments the launched process needs so its own hook
    /// wiring travels with it, rather than being written to a file other
    /// sessions could also read. Empty for an agent kind `supportsHooks`
    /// doesn't recognize, or for a kind (Antigravity) whose wiring instead
    /// goes through `configureHooks`'s shared-file write.
    ///
    /// For Claude Code: a `--settings '<json>'` flag carrying only this
    /// session's own `Notification`/`Stop`/`PostToolUse` hook groups, each
    /// running a shell one-liner that forwards the hook's own JSON stdin —
    /// which already carries `hook_event_name` — into `eventFilePath`.
    /// Claude Code merges `--settings` additively with the project's own
    /// `.claude/settings.json` rather than replacing it, so nothing a user
    /// or another tool configured there is disturbed.
    public static func launchArguments(
        for kind: AgentKind,
        sessionID: UUID,
        supportDirectory: URL
    ) -> [String] {
        guard supportsHooks(for: kind) else { return [] }

        switch kind {
        case .claudeCode:
            let eventFile = eventFilePath(for: sessionID, supportDirectory: supportDirectory)
            let command = shellCommand(appendingTo: eventFile)
            let hookGroup: [String: Any] = [
                "hooks": [
                    ["type": "command", "command": command]
                ]
            ]
            let settings: [String: Any] = [
                "hooks": [
                    "Notification": [hookGroup],
                    "Stop": [hookGroup],
                    "PostToolUse": [hookGroup]
                ]
            ]
            guard let data = try? JSONSerialization.data(withJSONObject: settings, options: [.sortedKeys]),
                  let json = String(data: data, encoding: .utf8) else {
                return []
            }
            return ["--settings", json]
        case .codexCLI, .openCode, .antigravity:
            return []
        }
    }

    /// Appends the hook's stdin JSON verbatim, plus a trailing newline —
    /// Claude sends one compact JSON object per hook invocation with no
    /// terminator, so the newline is what keeps the file line-delimited.
    private static func shellCommand(appendingTo eventFile: URL) -> String {
        let path = eventFile.path.replacingOccurrences(of: "\"", with: "\\\"")
        return "cat >> \"\(path)\" && printf '\\n' >> \"\(path)\""
    }

    // MARK: - Antigravity

    /// Writes this session's wrapper script and merges its hook group into
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
    /// Only `PreToolUse`/`PostToolUse` (matcher `*`, catching every tool
    /// call) and `Stop` are wired. `HookEventReceiver` decides `working` vs.
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
    /// (A `planFinished`-shaped signal — `PostToolUse` where
    /// `toolCall.name == "write_to_file"` and
    /// `args.ArtifactMetadata.RequestFeedback == true` — was also found but
    /// has no corresponding `SessionStatus` case; this is where its
    /// detection would hook in if that case is ever added.)
    private static func configureAntigravityHooks(
        sessionID: UUID,
        workingDirectory: URL,
        supportDirectory: URL,
        eventFile: URL
    ) -> Bool {
        let scriptPath = antigravityWrapperScriptPath(for: sessionID, supportDirectory: supportDirectory)
        do {
            try FileManager.default.createDirectory(
                at: scriptPath.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let contents = wrapperScriptContents(eventFile: eventFile, decisionRequiredFor: ["PreToolUse"])
            try Data(contents.utf8).write(to: scriptPath, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: scriptPath.path)
        } catch {
            return false
        }

        let configDirectory = workingDirectory.appendingPathComponent(".agents", isDirectory: true)
        let configFile = configDirectory.appendingPathComponent("hooks.json", isDirectory: false)

        // This session's own filename uniquely identifies any hook group
        // this method previously wrote for it — every other session's
        // command references a different script path. That's what makes
        // the replace-not-append below safe: it only ever touches this
        // session's own entries, never a sibling session's.
        let sessionMarker = scriptPath.lastPathComponent

        sharedConfigFileLock.lock()
        defer { sharedConfigFileLock.unlock() }

        var root: [String: Any] = [:]
        if let existing = try? Data(contentsOf: configFile),
           let decoded = try? JSONSerialization.jsonObject(with: existing) as? [String: Any] {
            root = decoded
        }

        var group = root["flotilla-status"] as? [String: Any] ?? [:]
        for event in ["PreToolUse", "PostToolUse"] {
            var entries = group[event] as? [[String: Any]] ?? []
            entries.removeAll { entry in
                Self.commands(in: entry).contains { $0.contains(sessionMarker) }
            }
            entries.append([
                "matcher": "*",
                "hooks": [
                    ["type": "command", "command": "\(Self.quoted(scriptPath.path)) \(event)", "timeout": 10]
                ]
            ])
            group[event] = entries
        }
        var stopEntries = group["Stop"] as? [[String: Any]] ?? []
        stopEntries.removeAll { entry in
            (entry["command"] as? String)?.contains(sessionMarker) == true
        }
        stopEntries.append([
            "type": "command",
            "command": "\(Self.quoted(scriptPath.path)) Stop",
            "timeout": 10
        ])
        group["Stop"] = stopEntries
        root["flotilla-status"] = group

        do {
            try FileManager.default.createDirectory(at: configDirectory, withIntermediateDirectories: true)
            let data = try JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys])
            try data.write(to: configFile, options: .atomic)
            return true
        } catch {
            return false
        }
    }

    private static func commands(in entry: [String: Any]) -> [String] {
        guard let hooks = entry["hooks"] as? [[String: Any]] else { return [] }
        return hooks.compactMap { $0["command"] as? String }
    }

    private static func quoted(_ path: String) -> String {
        "\"\(path.replacingOccurrences(of: "\"", with: "\\\""))\""
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
    private static func wrapperScriptContents(eventFile: URL, decisionRequiredFor: Set<String>) -> String {
        let path = eventFile.path.replacingOccurrences(of: "\"", with: "\\\"")
        var script = """
        #!/bin/sh
        event="$1"
        payload="$(cat)"
        printf '{"event":"%s","payload":%s}\\n' "$event" "$payload" >> "\(path)"
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

    /// Writes this session's wrapper script and merges its hook group into
    /// `<workingDirectory>/.codex/hooks.json`. See this file's top-level doc
    /// comment for the assumptions this rests on and why `PermissionRequest`
    /// is deliberately not wired here.
    ///
    /// Only `PostToolUse` (→ `working`) and `Stop` (→ `ready`) are wired —
    /// both fire-and-forget/informational in Claude Code's equivalent
    /// events, unlike the decision-blocking `PermissionRequest`, so no event
    /// here needs the `{"decision":"allow"}` stdout contract Antigravity's
    /// `PreToolUse` does. `waitingForInput` (both the free-text-question and
    /// permission-prompt cases) stays on `TerminalScreenHeuristic` for this
    /// provider until `PermissionRequest`'s response contract is verified.
    private static func configureCodexHooks(
        sessionID: UUID,
        workingDirectory: URL,
        supportDirectory: URL,
        eventFile: URL
    ) -> Bool {
        let scriptPath = codexWrapperScriptPath(for: sessionID, supportDirectory: supportDirectory)
        do {
            try FileManager.default.createDirectory(
                at: scriptPath.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let contents = wrapperScriptContents(eventFile: eventFile, decisionRequiredFor: [])
            try Data(contents.utf8).write(to: scriptPath, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: scriptPath.path)
        } catch {
            return false
        }

        let configDirectory = workingDirectory.appendingPathComponent(".codex", isDirectory: true)
        let configFile = configDirectory.appendingPathComponent("hooks.json", isDirectory: false)

        // Same idempotent-replace-by-marker approach as Antigravity's
        // shared file — see that method's comment for why it's safe.
        let sessionMarker = scriptPath.lastPathComponent

        sharedConfigFileLock.lock()
        defer { sharedConfigFileLock.unlock() }

        var settings: [String: Any] = [:]
        if let existing = try? Data(contentsOf: configFile),
           let decoded = try? JSONSerialization.jsonObject(with: existing) as? [String: Any] {
            settings = decoded
        }

        var hooks = settings["hooks"] as? [String: Any] ?? [:]
        for event in ["PostToolUse", "Stop"] {
            var groups = hooks[event] as? [[String: Any]] ?? []
            groups.removeAll { group in
                Self.commands(in: group).contains { $0.contains(sessionMarker) }
            }
            groups.append([
                "matcher": "",
                "hooks": [
                    ["type": "command", "command": "\(Self.quoted(scriptPath.path)) \(event)"]
                ]
            ])
            hooks[event] = groups
        }
        settings["hooks"] = hooks

        do {
            try FileManager.default.createDirectory(at: configDirectory, withIntermediateDirectories: true)
            let data = try JSONSerialization.data(withJSONObject: settings, options: [.prettyPrinted, .sortedKeys])
            try data.write(to: configFile, options: .atomic)
            return true
        } catch {
            return false
        }
    }
}

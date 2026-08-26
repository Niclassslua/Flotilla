import Foundation
import SessionKit

/// Wires a launching agent's own event mechanism to a per-session status
/// file, so `HookEventReceiver` can read exact, structured status instead
/// of `TerminalScreenHeuristic` guessing from rendered text.
///
/// Only Claude Code is wired today — its `hooks` config (JSON, per-event
/// shell command, documented at claude.ai/code) is expressive enough to
/// cover working/waiting/ready with three events. Codex's `notify`
/// mechanism is coarser and is a deliberate fast-follow, not implemented
/// here; every other agent kind falls back to `TerminalScreenHeuristic`
/// permanently — this is not a temporary gap to be filled in later.
public struct HookConfigurationWriter: Sendable {
    public init() {}

    /// Guards the read-modify-write below. Agent-managed-worktree sessions
    /// all launch with `workingDirectory` set to the *project root* (the
    /// agent creates its own worktree later), so every such session in the
    /// same project shares one `.claude/settings.json`. Two sessions
    /// launched close together previously raced an unguarded read-modify-
    /// write on that file — a lost update at best. One process-wide lock is
    /// enough: the critical section is a small synchronous file write, and
    /// nothing outside this type touches the file.
    private static let settingsFileLock = NSLock()

    /// Whether `configureHooks` can do anything useful for this agent kind.
    /// `HookCoordinator` checks this before bothering to spin up a
    /// `HookEventReceiver`.
    public static func supportsHooks(for kind: AgentKind) -> Bool {
        kind == .claudeCode
    }

    /// The append-only file a launched session's hook command writes one
    /// JSON line to per event, and that `HookEventReceiver` tails.
    public static func eventFilePath(for sessionID: UUID, supportDirectory: URL) -> URL {
        supportDirectory
            .appendingPathComponent("hooks", isDirectory: true)
            .appendingPathComponent("\(sessionID.uuidString).jsonl", isDirectory: false)
    }

    /// Merges a `hooks` block into `<workingDirectory>/.claude/settings.json`
    /// for `Notification`, `Stop`, and `PostToolUse`, each appending (never
    /// replacing) a hook group that runs a shell one-liner forwarding the
    /// hook's own JSON stdin — which already carries `hook_event_name` — into
    /// `eventFilePath`. Every other key already in the file, and any other
    /// hook already configured for these events, is preserved untouched.
    ///
    /// Best-effort by design: returns `false` (does not throw) when the
    /// agent kind isn't hook-capable or the write fails, so a broken/
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

        let settingsDirectory = workingDirectory.appendingPathComponent(".claude", isDirectory: true)
        let settingsFile = settingsDirectory.appendingPathComponent("settings.json", isDirectory: false)

        // This session's own filename (`<uuid>.jsonl`) uniquely identifies
        // any hook group this method previously wrote for it — every other
        // session's command references a different filename. That's what
        // makes the replace-not-append below safe: it only ever touches
        // this session's own entries, never a sibling session's.
        let sessionMarker = eventFile.lastPathComponent

        Self.settingsFileLock.lock()
        defer { Self.settingsFileLock.unlock() }

        var settings: [String: Any] = [:]
        if let existing = try? Data(contentsOf: settingsFile),
           let decoded = try? JSONSerialization.jsonObject(with: existing) as? [String: Any] {
            settings = decoded
        }

        var hooks = settings["hooks"] as? [String: Any] ?? [:]
        let command = Self.shellCommand(appendingTo: eventFile)
        for event in ["Notification", "Stop", "PostToolUse"] {
            var groups = hooks[event] as? [[String: Any]] ?? []
            // Idempotent: drop any group this session wrote on a previous
            // start/resume/restart before appending the fresh one, so
            // relaunching the same session doesn't accumulate duplicate
            // hook groups in this shared file forever.
            groups.removeAll { group in
                Self.commands(in: group).contains { $0.contains(sessionMarker) }
            }
            groups.append([
                "hooks": [
                    ["type": "command", "command": command]
                ]
            ])
            hooks[event] = groups
        }
        settings["hooks"] = hooks

        do {
            try FileManager.default.createDirectory(at: settingsDirectory, withIntermediateDirectories: true)
            let data = try JSONSerialization.data(withJSONObject: settings, options: [.prettyPrinted, .sortedKeys])
            try data.write(to: settingsFile, options: .atomic)
            return true
        } catch {
            return false
        }
    }

    private static func commands(in group: [String: Any]) -> [String] {
        guard let entries = group["hooks"] as? [[String: Any]] else { return [] }
        return entries.compactMap { $0["command"] as? String }
    }

    /// Appends the hook's stdin JSON verbatim, plus a trailing newline —
    /// Claude sends one compact JSON object per hook invocation with no
    /// terminator, so the newline is what keeps the file line-delimited.
    private static func shellCommand(appendingTo eventFile: URL) -> String {
        let path = eventFile.path.replacingOccurrences(of: "\"", with: "\\\"")
        return "cat >> \"\(path)\" && printf '\\n' >> \"\(path)\""
    }
}

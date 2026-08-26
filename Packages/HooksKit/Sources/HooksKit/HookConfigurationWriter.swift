import Foundation
import SessionKit

/// Wires a launching agent's own event mechanism to a per-session status
/// file, so `HookEventReceiver` can read exact, structured status instead
/// of `TerminalScreenHeuristic` guessing from rendered text.
///
/// Only Claude Code is wired today — its `hooks` config (JSON, per-event
/// shell command, documented at claude.ai/code) is expressive enough to
/// cover working/waiting/ready with three events. Every other agent kind
/// falls back to `TerminalScreenHeuristic` permanently for now — this is
/// not a temporary gap to be filled in later, it's tracked as separate,
/// per-provider follow-up work.
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
public struct HookConfigurationWriter: Sendable {
    public init() {}

    /// Whether `configureHooks`/`launchArguments` can do anything useful for
    /// this agent kind. `HookCoordinator` checks this before bothering to
    /// spin up a `HookEventReceiver`.
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

    /// Prepares `eventFilePath` for a fresh launch. This is the only
    /// filesystem side effect left in `configureHooks` — the hook wiring
    /// itself now travels with the launched process via `launchArguments`,
    /// not through a file other sessions could also read or write.
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
            return true
        } catch {
            return false
        }
    }

    /// Extra CLI arguments the launched process needs so its own hook
    /// wiring travels with it, rather than being written to a file other
    /// sessions could also read. Empty for an agent kind `supportsHooks`
    /// doesn't recognize, or when `configureHooks` hasn't successfully
    /// prepared this session's event file (there would be nothing valid to
    /// point the hooks at).
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
}

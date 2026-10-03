import Foundation
import SessionKit

/// Tells an agent that it runs inside Flotilla, so it does not quit the app
/// hosting it.
///
/// Agents restarting "the app" — to load a fresh build, or to unstick
/// something — reach for `killall`, `pkill`, or `osascript … quit`, and
/// nothing told them that the process they were about to kill hosts their
/// own session and every other one. Two channels close that gap:
///
/// - **Environment**: `FLOTILLA_HOST_APP` carries the host's bundle
///   identifier, so scripts can tell they run under Flotilla (the repo's
///   `make install` uses it to skip quitting the app).
/// - **Instructions**: appended to the agent's system prompt where the CLI
///   has a flag for it — every launch, resumes included, without touching
///   the user's goal. OpenCode, Antigravity, and Cursor Agent have no such
///   flag and only get the environment variable.
enum HostAppAwareness {
    static let environmentKey = "FLOTILLA_HOST_APP"

    struct Host: Equatable {
        let name: String
        let bundleIdentifier: String

        static var current: Host {
            Host(
                name: ProcessInfo.processInfo.processName,
                bundleIdentifier: Bundle.main.bundleIdentifier ?? "com.niclassslua.flotilla"
            )
        }
    }

    static func instructions(for host: Host) -> String {
        """
        You are running inside \(host.name), the macOS app (bundle identifier \
        \(host.bundleIdentifier)) that hosts this terminal session and other coding agents' \
        sessions. Never quit, kill, or restart \(host.name) — no `killall`/`pkill` matching \
        it, no `kill` on its PID, no `osascript` quit, no `open -a` relaunch. Doing so ends \
        this session and every other running agent session. If your work seems to need \
        \(host.name) restarted (for example to load a newly installed build), finish the \
        task and ask the user to restart it. Other builds with a different name, such as a \
        debug build you launched yourself, are fine to quit.
        """
    }

    static func launchArguments(for agent: AgentKind, host: Host = .current) -> [String] {
        let text = instructions(for: host)
        switch agent {
        case .claudeCode:
            return ["--append-system-prompt", text]
        case .codexCLI:
            // Overrides a `developer_instructions` from the user's own
            // config.toml for this session; Codex has no append form.
            return ["--config", "developer_instructions=\(tomlStringLiteral(text))"]
        case .openCode, .antigravity, .cursorAgent:
            return []
        }
    }

    /// A JSON string is a valid TOML basic string for this text: both escape
    /// `"`, `\`, and control characters the same way.
    private static func tomlStringLiteral(_ value: String) -> String {
        guard let data = try? JSONSerialization.data(
            withJSONObject: value,
            options: [.fragmentsAllowed, .withoutEscapingSlashes]
        ), let encoded = String(data: data, encoding: .utf8) else {
            return "\"\""
        }
        return encoded
    }
}

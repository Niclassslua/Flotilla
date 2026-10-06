import Foundation

/// What Cursor Agent's TUI is waiting on, read from the bottom of its pane.
///
/// No Cursor hook reports an open dialog — a skipped approval even arrives
/// as an ordinary `afterShellExecution`/`postToolUse` — so the screen is the
/// only source. Shared by the board's status (`TerminalScreenHeuristic`) and
/// the companion (`CursorCompanionAdapter`), which answers it with keys.
/// Strings are Cursor Agent 2026.10.01's (docs/providers/cursor-agent.md).
public enum CursorDialog: Equatable, Sendable {
    /// "Run this command?", "Allow this web fetch?": `y` runs, Tab runs
    /// and allowlists, `n` skips.
    case approval(question: String, subject: String, canAlwaysAllow: Bool)
    /// "Ready to build?": `b` builds, `p` asks for a revision.
    case plan(path: String?)
    /// Someone at the Mac is typing a skip reason or plan revision.
    case typing

    public static func parse(_ screen: String) -> CursorDialog? {
        let lines = screen.components(separatedBy: "\n").suffix(60).map {
            $0.trimmingCharacters(in: CharacterSet(charactersIn: "│┃ "))
        }
        if lines.contains(where: {
            $0.hasPrefix("→ Tell the agent what to do instead") || $0.hasPrefix("→ Describe how to revise the plan")
        }) {
            return .typing
        }
        if let ask = lines.lastIndex(where: { $0 == "Ready to build?" }),
           lines[ask...].contains(where: { $0.hasSuffix("(b)") }) {
            return .plan(path: planPath(in: Array(lines[..<ask])))
        }
        guard let yes = lines.lastIndex(where: { $0.hasSuffix("(y)") }),
              lines[yes...].contains(where: { $0.hasSuffix("(esc or n)") }),
              let question = lines[..<yes].lastIndex(where: { $0.hasSuffix("?") })
        else { return nil }
        let top = lines[..<question].lastIndex(where: { $0.hasPrefix("──") }) ?? question - 1
        let subject = lines[(top + 1)..<question]
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        return .approval(
            question: lines[question],
            subject: subject,
            canAlwaysAllow: lines[yes...].contains { $0.hasSuffix("(tab)") }
        )
    }

    /// `Saved to Users/…/.cursor/plans/Name-1a2b.plan.md`, wrapped over as
    /// many lines as the pane needs and printed without its leading slash.
    public static func planPath(in lines: [String]) -> String? {
        guard let start = lines.lastIndex(where: { $0.hasPrefix("Saved to ") }) else { return nil }
        var path = String(lines[start].dropFirst("Saved to ".count))
        var next = start + 1
        while !path.hasSuffix(".plan.md"), next < lines.count, !lines[next].isEmpty {
            path += lines[next]
            next += 1
        }
        guard path.hasSuffix(".plan.md") else { return nil }
        return path.hasPrefix("/") ? path : "/" + path
    }
}

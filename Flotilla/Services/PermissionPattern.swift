import Foundation
import HooksKit

/// Groups a raw permission ask into the pattern Home's Top permissions
/// widget counts against — coarse enough that "ran `npm install` 11 times"
/// reads as one line, not eleven.
enum PermissionPattern {
    /// A short glyph for the widget row, chosen by tool family rather than
    /// the exact tool name so Claude's and Codex's naming differences don't
    /// matter here.
    static func glyph(forTool tool: String) -> String {
        switch tool.lowercased() {
        case "bash", "shell", "exec", "local_shell": "terminal"
        case "edit", "write", "multiedit", "notebookedit": "pencil"
        case "webfetch": "globe"
        default: "app.badge"
        }
    }

    /// - Bash: the first two words plus `*` (`npm install *`); a single-word
    ///   command stays as-is (`git push`).
    /// - Edit/Write: the top-level path component plus `/**`.
    /// - WebFetch: the host.
    /// - Anything else: the tool name alone.
    static func normalize(event: HookPermissionRequestEvent) -> String {
        let tool = event.toolName
        guard let argument = event.primaryArgument, !argument.isEmpty else { return tool }
        switch tool.lowercased() {
        case "bash", "shell", "exec", "local_shell":
            return bashPattern(command: argument)
        case "edit", "write", "multiedit", "notebookedit":
            return pathPattern(path: argument)
        case "webfetch":
            return URL(string: argument)?.host ?? argument
        default:
            return tool
        }
    }

    private static func bashPattern(command: String) -> String {
        let words = command
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .split(separator: " ", maxSplits: 2, omittingEmptySubsequences: true)
        guard let first = words.first else { return "bash" }
        guard words.count > 1 else { return String(first) }
        return "\(first) \(words[1]) *"
    }

    private static func pathPattern(path: String) -> String {
        // The top-level path component relative to whatever's given —
        // typically already project-relative from the tool's own input.
        let trimmed = path.hasPrefix("/") ? String(path.dropFirst()) : path
        let top = trimmed.split(separator: "/").first.map(String.init) ?? trimmed
        return top.isEmpty ? "**" : "\(top)/**"
    }
}

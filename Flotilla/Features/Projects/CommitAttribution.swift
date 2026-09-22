import Foundation
import SessionKit

// MARK: - Attribution Model

struct CommitAttribution: Equatable {
    enum Source: Equatable {
        /// A marker committed with the change (Shared mode).
        case repository
        /// Recorded in Flotilla's database (On this Mac mode).
        case thisMac
        case trailer
        case sessionBranch
        case authorIdentity

        var explanation: String {
            switch self {
            case .repository: return "Recorded in the repository"
            case .thisMac: return "Recorded on this Mac"
            case .trailer: return "Recorded in the commit by Flotilla"
            case .sessionBranch: return "Only on this session's branch"
            case .authorIdentity: return "Committed under the agent's git identity"
            }
        }
    }

    let agent: AgentKind
    /// The model picked when the session launched; `nil` for the agent's
    /// default or when it isn't known.
    let model: String?
    let sessionID: UUID?
    let sessionTitle: String?
    /// The session's initial prompt.
    let prompt: String?
    let branchName: String?
    let source: Source

    var displayName: String { sessionTitle ?? agent.displayName }
}

extension AgentKind {
    static func inferredFromGitIdentity(name: String, email: String) -> AgentKind? {
        let name = name.lowercased()
        let email = email.lowercased()
        let domain = email.split(separator: "@").last.map(String.init) ?? ""

        if domain == "anthropic.com" || name == "claude code" || name == "claude" {
            return .claudeCode
        }
        if name == "codex" || name == "codex cli" || email.hasPrefix("codex@") {
            return .codexCLI
        }
        if name == "opencode" || domain == "opencode.ai" || email.hasPrefix("opencode@") {
            return .openCode
        }
        if name == "antigravity" || email.hasPrefix("antigravity@") {
            return .antigravity
        }
        if name == "cursor" || name == "cursor agent" || email.hasPrefix("cursor@") {
            return .cursorAgent
        }
        return nil
    }

    static func fromTrailerValue(_ value: String) -> AgentKind? {
        AgentKind(rawValue: value.trimmingCharacters(in: .whitespaces))
    }
}


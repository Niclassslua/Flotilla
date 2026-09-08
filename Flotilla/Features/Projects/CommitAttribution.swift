import Foundation
import SessionKit

// MARK: - Attribution Model

struct CommitAttribution: Equatable {
    enum Source: Equatable {
        case trailer
        case sessionBranch
        case authorIdentity

        var explanation: String {
            switch self {
            case .trailer: return "Recorded in the commit by Flotilla"
            case .sessionBranch: return "Only on this session's branch"
            case .authorIdentity: return "Committed under the agent's git identity"
            }
        }
    }

    let agent: AgentKind
    let sessionID: UUID?
    let sessionTitle: String?
    let sessionGoal: String?
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
        return nil
    }

    static func fromTrailerValue(_ value: String) -> AgentKind? {
        AgentKind(rawValue: value.trimmingCharacters(in: .whitespaces))
    }
}


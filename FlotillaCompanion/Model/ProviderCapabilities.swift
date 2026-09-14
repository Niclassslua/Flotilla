import Foundation
import SessionKit
import CompanionKit

/// How each provider differs in ways the UI has to express. Views read these
/// values instead of switching on `AgentKind`, so a provider's behaviour is
/// described in one place (see `Ideas/mobile-companion/capability-matrix.md`).
struct ProviderCapabilities: Sendable {
    enum StreamingGranularity: Sendable {
        case lines
        case tokens
        /// Completed steps only; a terminal-tail preview stands in meanwhile.
        case stepsWithTerminalTail
    }

    enum AlwaysAllowScope: Sendable {
        case session
        case commandPattern
        case conversation
    }

    var streaming: StreamingGranularity
    /// Claude Code offers Approve & auto-accept / Approve & ask for edits.
    var planApprovalHasModeSplit: Bool
    var alwaysAllowScope: AlwaysAllowScope

    static func of(_ agent: AgentKind) -> ProviderCapabilities {
        switch agent {
        case .claudeCode:
            ProviderCapabilities(streaming: .lines, planApprovalHasModeSplit: true, alwaysAllowScope: .session)
        case .codexCLI:
            ProviderCapabilities(streaming: .tokens, planApprovalHasModeSplit: false, alwaysAllowScope: .session)
        case .openCode:
            ProviderCapabilities(streaming: .tokens, planApprovalHasModeSplit: false, alwaysAllowScope: .commandPattern)
        case .antigravity:
            ProviderCapabilities(streaming: .stepsWithTerminalTail, planApprovalHasModeSplit: false, alwaysAllowScope: .conversation)
        }
    }

    func alwaysAllowLabel(for request: PermissionRequest) -> String {
        switch alwaysAllowScope {
        case .session:
            "Always allow for this session"
        case .commandPattern:
            "Always allow for “\(request.pattern ?? request.summary)”"
        case .conversation:
            "Always allow in this conversation"
        }
    }
}

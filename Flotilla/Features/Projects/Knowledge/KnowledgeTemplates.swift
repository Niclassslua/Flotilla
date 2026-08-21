import Foundation

/// Starter instruction files offered by the Rules tab's "Add Template" menu.
///
/// Lifted out of `ProjectRulesView` so the four designs can all offer the same
/// menu without carrying 90 lines of string literals apiece.
enum KnowledgeTemplate: String, CaseIterable, Identifiable {
    case agents = "AGENTS.md"
    case claude = "CLAUDE.md"
    case gemini = "GEMINI.md"
    case cursor = ".cursorrules"
    case copilot = "copilot-instructions.md"

    var id: String { rawValue }
    var fileName: String { rawValue }

    var menuTitle: String {
        switch self {
        case .agents: return "Create AGENTS.md Guide"
        case .claude: return "Create CLAUDE.md Rules"
        case .gemini: return "Create GEMINI.md Rules"
        case .cursor: return "Create .cursorrules"
        case .copilot: return "Create copilot-instructions.md"
        }
    }

    func content(projectName: String) -> String {
        switch self {
        case .agents:
            return """
            # \(projectName) — Agent Guide

            > Guidelines and architecture reference for AI coding assistants working on \(projectName).

            ## Project Overview
            - **Language / Stack:** 
            - **Build System:** 
            - **Primary Entrypoint:** 

            ## Development Commands
            - **Build:** 
            - **Test:** 
            - **Lint:** 

            ## Architecture & Conventions
            - 
            """
        case .claude:
            return """
            # Claude Code Rules for \(projectName)

            ## Guidelines
            - Always run unit tests before and after making code changes.
            - Maintain strict concurrency and type safety.
            - Keep functions focused and modular.
            """
        case .gemini:
            return """
            # Gemini CLI Instructions for \(projectName)

            ## Project Context
            - Architectural conventions and coding guidelines for \(projectName).
            - Test before committing changes.
            """
        case .cursor:
            return """
            # Rules for \(projectName)

            - Follow clean architecture patterns.
            - Ensure all public APIs are properly documented.
            - Never modify generated files directly.
            """
        case .copilot:
            return """
            # GitHub Copilot Instructions for \(projectName)

            - Use modern idioms and strictly type-safe constructs.
            - Maintain unit tests alongside all logic changes.
            """
        }
    }
}

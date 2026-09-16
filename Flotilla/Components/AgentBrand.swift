import SwiftUI
import SessionKit
import DesignSystem

/// Skill-framework brand colors. The per-`AgentKind` half of this lives in
/// `DesignSystem.AgentBrand`, shared with the iOS companion; `SkillFramework`
/// itself (Projects ▸ Knowledge) is macOS-only, so its accent/background
/// mapping stays here rather than in the shared package. Named distinctly
/// from `DesignSystem.AgentBrand` so both are usable, unqualified, in this
/// target without one shadowing the other.
enum SkillFrameworkBrand {
    /// Accent color for a skill framework, matching agent brand colors where
    /// applicable.
    ///
    /// Every case must resolve to a *distinct* color: these sit in one column
    /// of the skills ledger, where a color that repeats is worse than no color
    /// at all. Two used to collide — `.custom` fell through to the same accent
    /// as `.claude`, and `.gemini` inherited Antigravity's azure next to
    /// Codex's indigo — so both are pinned here instead of resolving through
    /// `agentKind`.
    static func accentColor(for framework: SkillFramework) -> Color {
        switch framework {
        case .gemini:
            // Still an Antigravity brand color, just not the one a glance
            // confuses with Codex.
            return DesignSystem.AgentBrand.antigravityGradientColors[1]
        case .custom:
            return Color(white: 0.55)
        case .cursor:
            return Color(white: 0.90)
        case .agents:
            return Color(red: 0.40, green: 0.70, blue: 0.65)
        case .claude, .codex:
            return framework.agentKind.map(DesignSystem.AgentBrand.accentColor(for:)) ?? FlotillaColors.accent
        }
    }

    /// Background color for framework badge / icon containers.
    static func iconBackgroundColor(for framework: SkillFramework, isHovered: Bool = false) -> Color {
        switch framework {
        case .cursor:
            return Color(white: 0.20).opacity(isHovered ? 0.8 : 0.5)
        case .agents:
            return FlotillaColors.surfaceElevated
        case .claude, .codex, .gemini, .custom:
            return accentColor(for: framework).opacity(isHovered ? 0.18 : 0.10)
        }
    }
}

extension SkillFramework {
    var accentColor: Color {
        SkillFrameworkBrand.accentColor(for: self)
    }

    func iconBackgroundColor(isHovered: Bool = false) -> Color {
        SkillFrameworkBrand.iconBackgroundColor(for: self, isHovered: isHovered)
    }
}

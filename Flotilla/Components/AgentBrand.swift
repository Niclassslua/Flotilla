import SwiftUI
import SessionKit
import DesignSystem

/// Real per-agent brand colors, distinct from `FlotillaColors`' semantic
/// status palette (which was only ever a stand-in here). Fixed hex values
/// rather than adaptive tokens — brand marks don't shift for light/dark the
/// way UI chrome does.
enum AgentBrand {
    /// Antigravity's 5-stop loop — first and last stop match, so it closes
    /// cleanly as a sweep. Nothing paints this as a sweep any more; it
    /// survives as the source of the individual brand stops that
    /// `accentColor` hands out.
    static let antigravityGradientColors: [Color] = [
        Color(red: 0x49 / 255, green: 0x86 / 255, blue: 0xF2 / 255), // #4986F2
        Color(red: 0x80 / 255, green: 0xBB / 255, blue: 0x74 / 255), // #80BB74
        Color(red: 0xE8 / 255, green: 0x8A / 255, blue: 0x3F / 255), // #E88A3F
        Color(red: 0xDB / 255, green: 0x5F / 255, blue: 0x4E / 255), // #DB5F4E
        Color(red: 0x49 / 255, green: 0x86 / 255, blue: 0xF2 / 255)  // #4986F2 — closes the loop
    ]

    /// A single representative color per agent — usable as a gradient stop,
    /// a wash, or anywhere a flat `Color` is required.
    static func accentColor(for kind: AgentKind) -> Color {
        switch kind {
        case .claudeCode: Color(red: 0xC6 / 255, green: 0x6F / 255, blue: 0x51 / 255) // #C66F51
        case .codexCLI: Color(red: 0x6D / 255, green: 0x8D / 255, blue: 0xF0 / 255) // #6D8DF0
        case .openCode: .white // #FFFFFF
        case .antigravity: Color(red: 0x79 / 255, green: 0xB3 / 255, blue: 0x6C / 255) // #79B36C
        }
    }

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
            return antigravityGradientColors[1]
        case .custom:
            return Color(white: 0.55)
        case .cursor:
            return Color(white: 0.90)
        case .agents:
            return Color(red: 0.40, green: 0.70, blue: 0.65)
        case .claude, .codex:
            return framework.agentKind.map(accentColor(for:)) ?? Color(red: 0.96, green: 0.36, blue: 0.16)
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

extension AgentKind {
    var accentColor: Color {
        AgentBrand.accentColor(for: self)
    }
}

extension SkillFramework {
    var accentColor: Color {
        AgentBrand.accentColor(for: self)
    }

    func iconBackgroundColor(isHovered: Bool = false) -> Color {
        AgentBrand.iconBackgroundColor(for: self, isHovered: isHovered)
    }
}

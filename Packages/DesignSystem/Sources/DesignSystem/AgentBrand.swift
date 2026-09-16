import SwiftUI
import SessionKit

/// Real per-agent brand colors, distinct from `FlotillaColors`' semantic
/// status palette (which was only ever a stand-in here). Fixed hex values
/// rather than adaptive tokens — brand marks don't shift for light/dark the
/// way UI chrome does.
///
/// Lives here, not in an app target, so the Mac app and the iOS companion
/// resolve agent brand colors identically (mirrors `StatusPresentation`).
/// The `SkillFramework`-based overloads stay in `Flotilla/Components/AgentBrand.swift`:
/// `SkillFramework` is a macOS-only type (Projects ▸ Knowledge), not shared
/// with the companion.
public enum AgentBrand {
    /// The flat blue the home composer's Antigravity wash paints
    /// (`LaunchpadDesign.backdrop`), in place of the brand gradient.
    public static let antigravityBackground = Color(red: 0x44 / 255, green: 0x7F / 255, blue: 0xED / 255) // #447FED

    /// Antigravity's 5-stop loop — first and last stop match, so it closes
    /// cleanly as a sweep. Nothing paints this as a sweep any more; it
    /// survives as the source of the individual brand stops that
    /// `accentColor` hands out.
    public static let antigravityGradientColors: [Color] = [
        Color(red: 0x49 / 255, green: 0x86 / 255, blue: 0xF2 / 255), // #4986F2
        Color(red: 0x80 / 255, green: 0xBB / 255, blue: 0x74 / 255), // #80BB74
        Color(red: 0xE8 / 255, green: 0x8A / 255, blue: 0x3F / 255), // #E88A3F
        Color(red: 0xDB / 255, green: 0x5F / 255, blue: 0x4E / 255), // #DB5F4E
        Color(red: 0x49 / 255, green: 0x86 / 255, blue: 0xF2 / 255)  // #4986F2 — closes the loop
    ]

    /// A single representative color per agent — usable as a gradient stop,
    /// a wash, or anywhere a flat `Color` is required. For Antigravity this
    /// is the anchor color its full gradient starts and ends on.
    public static func accentColor(for kind: AgentKind) -> Color {
        switch kind {
        case .claudeCode: FlotillaColors.accent
        case .codexCLI: Color(red: 0x40 / 255, green: 0x43 / 255, blue: 0xF5 / 255) // #4043F5
        case .openCode: .white // #FFFFFF
        case .antigravity: antigravityGradientColors[0]
        }
    }
}

public extension AgentKind {
    var accentColor: Color {
        AgentBrand.accentColor(for: self)
    }
}

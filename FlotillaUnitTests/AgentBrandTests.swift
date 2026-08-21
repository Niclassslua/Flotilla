import XCTest
import SwiftUI
import SessionKit
import DesignSystem
@testable import Flotilla

final class AgentBrandTests: XCTestCase {

    private func resolveRGB(_ color: Color, in appearanceName: NSAppearance.Name = .darkAqua) -> (r: CGFloat, g: CGFloat, b: CGFloat, a: CGFloat) {
        let appearance = NSAppearance(named: appearanceName)!
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        appearance.performAsCurrentDrawingAppearance {
            let nsColor = NSColor(color)
            if let rgbColor = nsColor.usingColorSpace(.sRGB) {
                rgbColor.getRed(&r, green: &g, blue: &b, alpha: &a)
            }
        }
        return (r, g, b, a)
    }

    private func assertColorsEqual(_ c1: Color, _ c2: Color, file: StaticString = #file, line: UInt = #line) {
        let rgb1Dark = resolveRGB(c1, in: .darkAqua)
        let rgb2Dark = resolveRGB(c2, in: .darkAqua)
        XCTAssertEqual(rgb1Dark.r, rgb2Dark.r, accuracy: 0.01, "Red mismatch (dark)", file: file, line: line)
        XCTAssertEqual(rgb1Dark.g, rgb2Dark.g, accuracy: 0.01, "Green mismatch (dark)", file: file, line: line)
        XCTAssertEqual(rgb1Dark.b, rgb2Dark.b, accuracy: 0.01, "Blue mismatch (dark)", file: file, line: line)
        XCTAssertEqual(rgb1Dark.a, rgb2Dark.a, accuracy: 0.01, "Alpha mismatch (dark)", file: file, line: line)

        let rgb1Light = resolveRGB(c1, in: .aqua)
        let rgb2Light = resolveRGB(c2, in: .aqua)
        XCTAssertEqual(rgb1Light.r, rgb2Light.r, accuracy: 0.01, "Red mismatch (light)", file: file, line: line)
        XCTAssertEqual(rgb1Light.g, rgb2Light.g, accuracy: 0.01, "Green mismatch (light)", file: file, line: line)
        XCTAssertEqual(rgb1Light.b, rgb2Light.b, accuracy: 0.01, "Blue mismatch (light)", file: file, line: line)
        XCTAssertEqual(rgb1Light.a, rgb2Light.a, accuracy: 0.01, "Alpha mismatch (light)", file: file, line: line)
    }

    func testAgentKindAccentColors() {
        assertColorsEqual(AgentBrand.accentColor(for: .claudeCode), FlotillaColors.accent)
        assertColorsEqual(AgentBrand.accentColor(for: .codexCLI), Color(red: 0x40 / 255, green: 0x43 / 255, blue: 0xF5 / 255))
        assertColorsEqual(AgentBrand.accentColor(for: .openCode), .white)
        assertColorsEqual(AgentBrand.accentColor(for: .antigravity), AgentBrand.antigravityGradientColors[0])
    }

    func testSkillFrameworkAgentKindMapping() {
        XCTAssertEqual(SkillFramework.claude.agentKind, .claudeCode)
        XCTAssertEqual(SkillFramework.codex.agentKind, .codexCLI)
        XCTAssertEqual(SkillFramework.gemini.agentKind, .antigravity)
        XCTAssertNil(SkillFramework.cursor.agentKind)
        XCTAssertNil(SkillFramework.agents.agentKind)
        XCTAssertNil(SkillFramework.custom.agentKind)
    }

    func testSkillFrameworkAccentColorsMatchAgentColors() {
        assertColorsEqual(
            AgentBrand.accentColor(for: SkillFramework.claude),
            AgentBrand.accentColor(for: AgentKind.claudeCode)
        )
        assertColorsEqual(
            AgentBrand.accentColor(for: SkillFramework.codex),
            AgentBrand.accentColor(for: AgentKind.codexCLI)
        )
        assertColorsEqual(
            AgentBrand.accentColor(for: SkillFramework.gemini),
            AgentBrand.accentColor(for: AgentKind.antigravity)
        )
        assertColorsEqual(AgentBrand.accentColor(for: SkillFramework.custom), FlotillaColors.accent)
        assertColorsEqual(AgentBrand.accentColor(for: SkillFramework.cursor), Color(white: 0.90))
        assertColorsEqual(AgentBrand.accentColor(for: SkillFramework.agents), Color(red: 0.40, green: 0.70, blue: 0.65))
    }

    func testSkillFrameworkConvenienceExtensions() {
        assertColorsEqual(SkillFramework.claude.accentColor, AgentBrand.accentColor(for: .claudeCode))
        assertColorsEqual(SkillFramework.codex.accentColor, AgentBrand.accentColor(for: .codexCLI))
        assertColorsEqual(SkillFramework.gemini.accentColor, AgentBrand.accentColor(for: .antigravity))
        assertColorsEqual(AgentKind.claudeCode.accentColor, FlotillaColors.accent)
    }

    func testIconBackgroundColors() {
        let claudeUnhovered = AgentBrand.iconBackgroundColor(for: .claude, isHovered: false)
        let claudeHovered = AgentBrand.iconBackgroundColor(for: .claude, isHovered: true)
        assertColorsEqual(claudeUnhovered, AgentBrand.accentColor(for: .claudeCode).opacity(0.10))
        assertColorsEqual(claudeHovered, AgentBrand.accentColor(for: .claudeCode).opacity(0.18))

        let agentsBg = AgentBrand.iconBackgroundColor(for: .agents, isHovered: false)
        assertColorsEqual(agentsBg, FlotillaColors.surfaceElevated)

        let cursorUnhovered = AgentBrand.iconBackgroundColor(for: .cursor, isHovered: false)
        let cursorHovered = AgentBrand.iconBackgroundColor(for: .cursor, isHovered: true)
        assertColorsEqual(cursorUnhovered, Color(white: 0.20).opacity(0.5))
        assertColorsEqual(cursorHovered, Color(white: 0.20).opacity(0.8))
    }
}

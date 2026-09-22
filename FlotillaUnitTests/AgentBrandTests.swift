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

    func testSkillFrameworkAgentKindMapping() {
        XCTAssertEqual(SkillFramework.claude.agentKind, .claudeCode)
        XCTAssertEqual(SkillFramework.codex.agentKind, .codexCLI)
        XCTAssertEqual(SkillFramework.gemini.agentKind, .antigravity)
        XCTAssertEqual(SkillFramework.cursor.agentKind, .cursorAgent)
        XCTAssertNil(SkillFramework.agents.agentKind)
        XCTAssertNil(SkillFramework.custom.agentKind)
    }

    /// These colors sit in one column of the skills ledger, so a repeat is
    /// worse than no color at all. Two used to collide: `.custom` fell through
    /// to the same accent as `.claude`, and `.gemini` inherited Antigravity's
    /// azure right beside Codex's indigo.
    func testSkillFrameworkAccentColorsAreAllDistinct() {
        let frameworks: [SkillFramework] = [.claude, .agents, .codex, .cursor, .gemini, .custom]
        for (offset, lhs) in frameworks.enumerated() {
            for rhs in frameworks.dropFirst(offset + 1) {
                let a = resolveRGB(AgentBrand.accentColor(for: lhs))
                let b = resolveRGB(AgentBrand.accentColor(for: rhs))
                let distance = abs(a.r - b.r) + abs(a.g - b.g) + abs(a.b - b.b)
                XCTAssertGreaterThan(
                    distance, 0.15,
                    "\(lhs.displayName) and \(rhs.displayName) are too close to tell apart in the ledger"
                )
            }
        }
    }

}

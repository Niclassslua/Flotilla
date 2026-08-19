import XCTest
@testable import Flotilla

final class MaterialFileIconTests: XCTestCase {

    func testSpecialFolderIcons() {
        let srcFolder = URL(fileURLWithPath: "/project/src")
        let gitFolder = URL(fileURLWithPath: "/project/.git")
        let testFolder = URL(fileURLWithPath: "/project/test")
        let randomFolder = URL(fileURLWithPath: "/project/custom_folder")

        let srcIcon = MaterialIconProvider.folderIcon(for: srcFolder)
        let gitIcon = MaterialIconProvider.folderIcon(for: gitFolder)
        let testIcon = MaterialIconProvider.folderIcon(for: testFolder)
        let defaultIcon = MaterialIconProvider.folderIcon(for: randomFolder)

        guard case .folder(_, let srcGlyph, _) = srcIcon,
              case .folder(_, let gitGlyph, _) = gitIcon,
              case .folder(_, let testGlyph, _) = testIcon,
              case .folder(_, let defaultGlyph, _) = defaultIcon else {
            return XCTFail("Expected folder icons")
        }

        XCTAssertEqual(srcGlyph, "chevron.left.forwardslash.chevron.right")
        XCTAssertEqual(gitGlyph, "arrow.triangle.branch")
        XCTAssertEqual(testGlyph, "flask.fill")
        XCTAssertNil(defaultGlyph)
    }

    func testExactFilenameMatches() {
        let pkgJson = MaterialIconProvider.fileIcon(for: URL(fileURLWithPath: "/project/package.json"))
        guard case .badge(let text, _, _, _) = pkgJson else {
            return XCTFail("Expected badge for package.json")
        }
        XCTAssertEqual(text, "npm")

        let lockFile = MaterialIconProvider.fileIcon(for: URL(fileURLWithPath: "/project/yarn.lock"))
        guard case .symbol(let name, _) = lockFile else {
            return XCTFail("Expected symbol for yarn.lock")
        }
        XCTAssertEqual(name, "lock.fill")

        let dockerfile = MaterialIconProvider.fileIcon(for: URL(fileURLWithPath: "/project/Dockerfile"))
        guard case .symbol(let name, _) = dockerfile else {
            return XCTFail("Expected symbol for Dockerfile")
        }
        XCTAssertEqual(name, "shippingbox.fill")

        // AI Rule files
        let claudeMd = MaterialIconProvider.fileIcon(for: URL(fileURLWithPath: "/project/CLAUDE.md"))
        guard case .badge(let claudeText, _, _, _) = claudeMd else {
            return XCTFail("Expected badge for CLAUDE.md")
        }
        XCTAssertEqual(claudeText, "CC")

        let agentsMd = MaterialIconProvider.fileIcon(for: URL(fileURLWithPath: "/project/AGENTS.md"))
        guard case .badge(let agentsText, _, _, _) = agentsMd else {
            return XCTFail("Expected badge for AGENTS.md")
        }
        XCTAssertEqual(agentsText, "AG")

        let cursorRules = MaterialIconProvider.fileIcon(for: URL(fileURLWithPath: "/project/.cursorrules"))
        guard case .badge(let cursorText, _, _, _) = cursorRules else {
            return XCTFail("Expected badge for .cursorrules")
        }
        XCTAssertEqual(cursorText, "CR")
    }

    func testLanguageBadgesAndSymbols() {
        // Swift
        let swiftIcon = MaterialIconProvider.fileIcon(for: URL(fileURLWithPath: "/App.swift"))
        guard case .symbol(let swiftName, _) = swiftIcon else {
            return XCTFail("Expected swift symbol")
        }
        XCTAssertEqual(swiftName, "swift")

        // TypeScript & JavaScript
        let tsIcon = MaterialIconProvider.fileIcon(for: URL(fileURLWithPath: "/index.ts"))
        if case .badge(let text, _, _, _) = tsIcon {
            XCTAssertEqual(text, "TS")
        } else {
            XCTFail("Expected TS badge")
        }

        let jsIcon = MaterialIconProvider.fileIcon(for: URL(fileURLWithPath: "/index.js"))
        if case .badge(let text, _, _, _) = jsIcon {
            XCTAssertEqual(text, "JS")
        } else {
            XCTFail("Expected JS badge")
        }

        // Markdown
        let mdIcon = MaterialIconProvider.fileIcon(for: URL(fileURLWithPath: "/docs.md"))
        if case .badge(let text, _, _, _) = mdIcon {
            XCTAssertEqual(text, "M↓")
        } else {
            XCTFail("Expected M↓ badge")
        }

        // Python
        let pyIcon = MaterialIconProvider.fileIcon(for: URL(fileURLWithPath: "/script.py"))
        if case .badge(let text, _, _, _) = pyIcon {
            XCTAssertEqual(text, "PY")
        } else {
            XCTFail("Expected PY badge")
        }
    }
}

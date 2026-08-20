import XCTest
@testable import Flotilla

final class MaterialFileIconTests: XCTestCase {

    func testFolderIconNames() {
        let srcFolder = URL(fileURLWithPath: "/project/src")
        let gitFolder = URL(fileURLWithPath: "/project/.git")
        let testFolder = URL(fileURLWithPath: "/project/test")
        let randomFolder = URL(fileURLWithPath: "/project/custom_folder")

        XCTAssertEqual(MaterialIconProvider.folderIconName(for: srcFolder, isExpanded: false), "folder-src")
        XCTAssertEqual(MaterialIconProvider.folderIconName(for: srcFolder, isExpanded: true), "folder-src-open")

        XCTAssertEqual(MaterialIconProvider.folderIconName(for: gitFolder), "folder-git")

        XCTAssertEqual(MaterialIconProvider.folderIconName(for: testFolder, isExpanded: false), "folder-test")
        XCTAssertEqual(MaterialIconProvider.folderIconName(for: testFolder, isExpanded: true), "folder-test-open")

        XCTAssertEqual(MaterialIconProvider.folderIconName(for: randomFolder, isExpanded: false), "folder")
        XCTAssertEqual(MaterialIconProvider.folderIconName(for: randomFolder, isExpanded: true), "folder-open")
    }

    func testExactFilenameMatches() {
        XCTAssertEqual(MaterialIconProvider.fileIconName(for: URL(fileURLWithPath: "/project/package.json")), "npm")
        XCTAssertEqual(MaterialIconProvider.fileIconName(for: URL(fileURLWithPath: "/project/yarn.lock")), "lock")
        XCTAssertEqual(MaterialIconProvider.fileIconName(for: URL(fileURLWithPath: "/project/Dockerfile")), "docker")
        XCTAssertEqual(MaterialIconProvider.fileIconName(for: URL(fileURLWithPath: "/project/.gitignore")), "git")

        // AI Rule files & Dot Configs
        XCTAssertEqual(MaterialIconProvider.fileIconName(for: URL(fileURLWithPath: "/project/CLAUDE.md")), "claude")
        XCTAssertEqual(MaterialIconProvider.fileIconName(for: URL(fileURLWithPath: "/project/GEMINI.md")), "gemini")
        XCTAssertEqual(MaterialIconProvider.fileIconName(for: URL(fileURLWithPath: "/project/.gemini")), "gemini")
        XCTAssertEqual(MaterialIconProvider.fileIconName(for: URL(fileURLWithPath: "/project/.geminirules")), "gemini")
        XCTAssertEqual(MaterialIconProvider.fileIconName(for: URL(fileURLWithPath: "/project/.antigravity")), "gemini")
        XCTAssertEqual(MaterialIconProvider.fileIconName(for: URL(fileURLWithPath: "/project/antigravity.md")), "gemini")
        XCTAssertEqual(MaterialIconProvider.fileIconName(for: URL(fileURLWithPath: "/project/.cursorrules")), "cursor")
        XCTAssertEqual(MaterialIconProvider.fileIconName(for: URL(fileURLWithPath: "/project/copilot-instructions.md")), "copilot")
        XCTAssertEqual(MaterialIconProvider.fileIconName(for: URL(fileURLWithPath: "/project/AGENTS.md")), "robot")
        XCTAssertEqual(MaterialIconProvider.fileIconName(for: URL(fileURLWithPath: "/project/SKILL.md")), "robot")

        // AI Folders
        XCTAssertEqual(MaterialIconProvider.folderIconName(for: URL(fileURLWithPath: "/project/.gemini")), "gemini")
        XCTAssertEqual(MaterialIconProvider.folderIconName(for: URL(fileURLWithPath: "/project/.antigravity")), "gemini")
        XCTAssertEqual(MaterialIconProvider.folderIconName(for: URL(fileURLWithPath: "/project/.claude")), "claude")
        XCTAssertEqual(MaterialIconProvider.folderIconName(for: URL(fileURLWithPath: "/project/.agents")), "robot")
    }

    func testLanguageExtensions() {
        XCTAssertEqual(MaterialIconProvider.fileIconName(for: URL(fileURLWithPath: "/App.swift")), "swift")
        XCTAssertEqual(MaterialIconProvider.fileIconName(for: URL(fileURLWithPath: "/index.ts")), "typescript")
        XCTAssertEqual(MaterialIconProvider.fileIconName(for: URL(fileURLWithPath: "/App.tsx")), "react_ts")
        XCTAssertEqual(MaterialIconProvider.fileIconName(for: URL(fileURLWithPath: "/index.js")), "javascript")
        XCTAssertEqual(MaterialIconProvider.fileIconName(for: URL(fileURLWithPath: "/App.jsx")), "react")
        XCTAssertEqual(MaterialIconProvider.fileIconName(for: URL(fileURLWithPath: "/main.py")), "python")
        XCTAssertEqual(MaterialIconProvider.fileIconName(for: URL(fileURLWithPath: "/lib.rs")), "rust")
        XCTAssertEqual(MaterialIconProvider.fileIconName(for: URL(fileURLWithPath: "/server.go")), "go")
        XCTAssertEqual(MaterialIconProvider.fileIconName(for: URL(fileURLWithPath: "/README.md")), "markdown")
        XCTAssertEqual(MaterialIconProvider.fileIconName(for: URL(fileURLWithPath: "/config.json")), "json")
        XCTAssertEqual(MaterialIconProvider.fileIconName(for: URL(fileURLWithPath: "/config.yaml")), "yaml")
    }

    func testSVGLoaderFindsVendoredIcons() {
        let swiftImage = MaterialIconCache.shared.image(named: "swift")
        XCTAssertNotNil(swiftImage, "Expected swift.svg to load")

        let folderSrcImage = MaterialIconCache.shared.image(named: "folder-src")
        XCTAssertNotNil(folderSrcImage, "Expected folder-src.svg to load")

        let claudeImage = MaterialIconCache.shared.image(named: "claude")
        XCTAssertNotNil(claudeImage, "Expected claude.svg to load")

        let geminiImage = MaterialIconCache.shared.image(named: "gemini")
        XCTAssertNotNil(geminiImage, "Expected gemini.svg to load")

        let cursorImage = MaterialIconCache.shared.image(named: "cursor")
        XCTAssertNotNil(cursorImage, "Expected cursor.svg to load")

        let copilotImage = MaterialIconCache.shared.image(named: "copilot")
        XCTAssertNotNil(copilotImage, "Expected copilot.svg to load")

        let robotImage = MaterialIconCache.shared.image(named: "robot")
        XCTAssertNotNil(robotImage, "Expected robot.svg to load")
    }
}

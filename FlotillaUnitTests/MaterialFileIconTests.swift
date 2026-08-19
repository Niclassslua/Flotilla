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

        // AI Rule files
        XCTAssertEqual(MaterialIconProvider.fileIconName(for: URL(fileURLWithPath: "/project/CLAUDE.md")), "robot")
        XCTAssertEqual(MaterialIconProvider.fileIconName(for: URL(fileURLWithPath: "/project/AGENTS.md")), "robot")
        XCTAssertEqual(MaterialIconProvider.fileIconName(for: URL(fileURLWithPath: "/project/.cursorrules")), "robot")
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

        let robotImage = MaterialIconCache.shared.image(named: "robot")
        XCTAssertNotNil(robotImage, "Expected robot.svg to load")
    }
}

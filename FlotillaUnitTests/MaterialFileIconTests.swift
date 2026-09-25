import XCTest
@testable import Flotilla

final class MaterialFileIconTests: XCTestCase {

    /// Representative precedence and fallback cases — not a full catalog mirror.
    func testIconNamePrecedenceAndFallback() {
        // Folder: specialized name beats generic; numeric names stay generic.
        XCTAssertEqual(MaterialIconProvider.folderIconName(for: URL(fileURLWithPath: "/project/src")), "folder-src")
        XCTAssertEqual(MaterialIconProvider.folderIconName(for: URL(fileURLWithPath: "/project/.git")), "folder-git")
        XCTAssertEqual(MaterialIconProvider.folderIconName(for: URL(fileURLWithPath: "/project/custom_folder")), "folder")
        XCTAssertEqual(MaterialIconProvider.folderIconName(for: URL(fileURLWithPath: "/project/1")), "folder")

        // Exact filename beats extension; AI rule files keep branded icons.
        XCTAssertEqual(MaterialIconProvider.fileIconName(for: URL(fileURLWithPath: "/project/package.json")), "npm")
        XCTAssertEqual(MaterialIconProvider.fileIconName(for: URL(fileURLWithPath: "/project/CLAUDE.md")), "claude")
        XCTAssertEqual(MaterialIconProvider.fileIconName(for: URL(fileURLWithPath: "/project/.cursorrules")), "cursor")
        XCTAssertEqual(MaterialIconProvider.folderIconName(for: URL(fileURLWithPath: "/project/.claude")), "claude")

        // Language extensions.
        XCTAssertEqual(MaterialIconProvider.fileIconName(for: URL(fileURLWithPath: "/App.swift")), "swift")
        XCTAssertEqual(MaterialIconProvider.fileIconName(for: URL(fileURLWithPath: "/App.tsx")), "react_ts")
        XCTAssertEqual(MaterialIconProvider.fileIconName(for: URL(fileURLWithPath: "/main.py")), "python")
    }

    func testPackagedAssetsAndVendoredSVGsLoad() {
        XCTAssertNotNil(NSImage(named: "GitLogo"), "GitLogo asset should be loadable from Asset Catalog")
        XCTAssertNotNil(NSImage(named: "GitBranch"), "GitBranch asset should be loadable from Asset Catalog")

        for name in ["swift", "folder-src", "claude", "gemini", "cursor", "copilot", "robot"] {
            XCTAssertNotNil(MaterialIconCache.shared.image(named: name), "Expected \(name).svg to load")
        }
    }
}

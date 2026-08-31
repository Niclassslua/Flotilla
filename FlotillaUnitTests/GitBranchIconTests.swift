import XCTest
import SwiftUI
@testable import Flotilla

final class GitBranchIconTests: XCTestCase {
    func testGitBranchAssetExists() {
        let image = NSImage(named: "GitBranch")
        XCTAssertNotNil(image, "GitBranch asset should be loadable from Asset Catalog")
    }

    func testGitBranchIconInitializes() {
        let icon = GitBranchIcon(size: 14)
        XCTAssertEqual(icon.size, 14)
    }

    func testGitBranchLabelInitializes() {
        let label = GitBranchLabel("feature/test", size: 12)
        XCTAssertEqual(label.title, "feature/test")
        XCTAssertEqual(label.size, 12)
    }
}

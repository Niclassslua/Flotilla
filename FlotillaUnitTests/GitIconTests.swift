import XCTest
import SwiftUI
@testable import Flotilla

final class GitIconTests: XCTestCase {
    func testGitLogoAssetExists() {
        let image = NSImage(named: "GitLogo")
        XCTAssertNotNil(image, "GitLogo asset should be loadable from Asset Catalog")
    }

    func testGitIconInitializes() {
        let icon = GitIcon(size: 14)
        XCTAssertEqual(icon.size, 14)
    }

    func testGitLabelInitializes() {
        let label = GitLabel("Git", size: 12)
        XCTAssertEqual(label.title, "Git")
        XCTAssertEqual(label.size, 12)
    }
}

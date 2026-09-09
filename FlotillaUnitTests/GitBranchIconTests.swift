import XCTest
import SwiftUI
@testable import Flotilla

final class GitBranchIconTests: XCTestCase {
    func testGitBranchAssetExists() {
        let image = NSImage(named: "GitBranch")
        XCTAssertNotNil(image, "GitBranch asset should be loadable from Asset Catalog")
    }

}

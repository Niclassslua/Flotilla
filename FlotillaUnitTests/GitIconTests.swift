import XCTest
import SwiftUI
@testable import Flotilla

final class GitIconTests: XCTestCase {
    func testGitLogoAssetExists() {
        let image = NSImage(named: "GitLogo")
        XCTAssertNotNil(image, "GitLogo asset should be loadable from Asset Catalog")
    }

}

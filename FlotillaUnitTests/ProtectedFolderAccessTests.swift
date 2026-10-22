import XCTest
@testable import Flotilla

final class ProtectedFolderAccessTests: XCTestCase {
    func testFolderNameForDocumentsSubtree() {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let path = home.appendingPathComponent("Documents/Projects/SwiftUi/Flotilla", isDirectory: true)
        XCTAssertEqual(ProtectedFolderAccess.folderName(containing: path), "Documents")
    }

    func testFolderNameForDesktop() {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let path = home.appendingPathComponent("Desktop", isDirectory: true)
        XCTAssertEqual(ProtectedFolderAccess.folderName(containing: path), "Desktop")
    }

    func testFolderNameOutsideProtectedRootsIsNil() {
        let path = URL(fileURLWithPath: "/tmp/flotilla-test")
        XCTAssertNil(ProtectedFolderAccess.folderName(containing: path))
    }

    func testDeniedMessagePointsAtFilesAndFolders() {
        let message = ProtectedFolderAccess.Denied(folderName: "Documents").errorDescription
        XCTAssertEqual(
            message,
            "macOS blocked access to Documents. Allow Flotilla access to Documents in System Settings → Privacy & Security → Files & Folders"
        )
        XCTAssertNotNil(ProtectedFolderAccess.Denied.settingsURL)
    }

    func testRequireReadableAllowsTmp() throws {
        try ProtectedFolderAccess.requireReadable(URL(fileURLWithPath: "/tmp"))
    }

    func testRequireReadableSkipsMissingPath() throws {
        let missing = URL(fileURLWithPath: "/tmp/flotilla-does-not-exist-\(UUID().uuidString)")
        try ProtectedFolderAccess.requireReadable(missing)
    }
}

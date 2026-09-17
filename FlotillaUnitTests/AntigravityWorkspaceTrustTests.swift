import XCTest
import AgentKit
import SessionKit
@testable import Flotilla

final class AntigravityWorkspaceTrustTests: XCTestCase {
    private var tempDirectory: URL!
    private var settingsURL: URL!

    override func setUp() {
        super.setUp()
        tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("flotilla-test-trust-\(UUID().uuidString)", isDirectory: true)
        settingsURL = tempDirectory.appendingPathComponent("settings.json", isDirectory: false)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tempDirectory)
        super.tearDown()
    }

    func testEnsureTrustedCreatesSettingsFileAndAddsWorkspace() throws {
        let workspace = tempDirectory.appendingPathComponent("my-workspace", isDirectory: true)
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)

        let modified = try AntigravityWorkspaceTrust.ensureTrusted(
            workspace: workspace,
            settingsURL: settingsURL
        )

        XCTAssertTrue(modified, "ensureTrusted should return true when writing a new entry")
        XCTAssertTrue(FileManager.default.fileExists(atPath: settingsURL.path))

        let data = try Data(contentsOf: settingsURL)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let trusted = try XCTUnwrap(json["trustedWorkspaces"] as? [String])

        XCTAssertTrue(trusted.contains(workspace.path))
        XCTAssertTrue(trusted.contains(workspace.resolvingSymlinksInPath().path))
    }

    func testEnsureTrustedIsIdempotentAndDoesNotDuplicate() throws {
        let workspace = tempDirectory.appendingPathComponent("my-workspace", isDirectory: true)
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)

        let first = try AntigravityWorkspaceTrust.ensureTrusted(
            workspace: workspace,
            settingsURL: settingsURL
        )
        XCTAssertTrue(first)

        let second = try AntigravityWorkspaceTrust.ensureTrusted(
            workspace: workspace,
            settingsURL: settingsURL
        )
        XCTAssertFalse(second, "Second call with the same workspace should not modify settings")

        let data = try Data(contentsOf: settingsURL)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let trusted = try XCTUnwrap(json["trustedWorkspaces"] as? [String])

        // Verify count of exact path is 1
        let matches = trusted.filter { $0 == workspace.path }
        XCTAssertEqual(matches.count, 1)
    }

    func testEnsureTrustedPreservesExistingSettingsAndAppends() throws {
        try FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)

        let initialSettings: [String: Any] = [
            "model": "gemini-3.7-flash-high",
            "toolPermission": "proceed-in-sandbox",
            "allowNonWorkspaceAccess": true,
            "trustedWorkspaces": ["/existing/trusted/folder"]
        ]
        let initialData = try JSONSerialization.data(withJSONObject: initialSettings, options: [.prettyPrinted])
        try initialData.write(to: settingsURL)

        let workspace = tempDirectory.appendingPathComponent("new-project", isDirectory: true)
        let modified = try AntigravityWorkspaceTrust.ensureTrusted(
            workspace: workspace,
            settingsURL: settingsURL
        )
        XCTAssertTrue(modified)

        let data = try Data(contentsOf: settingsURL)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])

        XCTAssertEqual(json["model"] as? String, "gemini-3.7-flash-high")
        XCTAssertEqual(json["toolPermission"] as? String, "proceed-in-sandbox")
        XCTAssertEqual(json["allowNonWorkspaceAccess"] as? Bool, true)

        let trusted = try XCTUnwrap(json["trustedWorkspaces"] as? [String])
        XCTAssertTrue(trusted.contains("/existing/trusted/folder"), "Existing trusted workspaces must be preserved")
        XCTAssertTrue(trusted.contains(workspace.path), "New workspace path must be appended")
    }

    func testEnsureTrustedDoesNotReplaceMalformedTrustedWorkspaces() throws {
        try FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)

        let initialSettings: [String: Any] = [
            "model": "gemini-3.7-flash-high",
            "trustedWorkspaces": ["unexpected": "object"]
        ]
        let initialData = try JSONSerialization.data(withJSONObject: initialSettings, options: [])
        try initialData.write(to: settingsURL)
        let originalData = try Data(contentsOf: settingsURL)

        let workspace = tempDirectory.appendingPathComponent("new-project", isDirectory: true)
        XCTAssertThrowsError(
            try AntigravityWorkspaceTrust.ensureTrusted(
                workspace: workspace,
                settingsURL: settingsURL
            )
        )
        XCTAssertEqual(try Data(contentsOf: settingsURL), originalData)
    }

    func testCandidatePathsNormalizesTrailingSlashes() {
        let urlWithSlash = URL(fileURLWithPath: "/path/to/project/")
        let candidates = AntigravityWorkspaceTrust.candidatePaths(for: urlWithSlash)
        for candidate in candidates {
            XCTAssertFalse(candidate.hasSuffix("/"), "Candidate paths should not have trailing slashes")
        }
        XCTAssertTrue(candidates.contains("/path/to/project"))
    }
}

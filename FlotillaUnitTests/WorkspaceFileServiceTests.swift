import XCTest
@testable import Flotilla

final class WorkspaceFileServiceTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("flotilla-files-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    func testDiscoversProjectRulesAndNestedSkillsButExcludesDependencies() async throws {
        let agents = root.appendingPathComponent(".agents/skills/review", isDirectory: true)
        let dependencies = root.appendingPathComponent("node_modules/vendor", isDirectory: true)
        try FileManager.default.createDirectory(at: agents, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: dependencies, withIntermediateDirectories: true)
        try "Root rules".write(to: root.appendingPathComponent("AGENTS.md"), atomically: true, encoding: .utf8)
        try "Skill rules".write(to: agents.appendingPathComponent("SKILL.md"), atomically: true, encoding: .utf8)
        try "Ignore me".write(to: dependencies.appendingPathComponent("CLAUDE.md"), atomically: true, encoding: .utf8)

        let entries = try await WorkspaceFileService().instructionFiles(in: root)

        XCTAssertEqual(entries.map(\.relativePath), [".agents/skills/review/SKILL.md", "AGENTS.md"])
    }

    func testReadAndWriteRoundTripPersistsToDisk() async throws {
        let file = root.appendingPathComponent("CLAUDE.md")
        try "Before".write(to: file, atomically: true, encoding: .utf8)
        let service = WorkspaceFileService()

        let before = try await service.readText(at: file)
        XCTAssertEqual(before, "Before")
        try await service.writeText("After", to: file)

        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), "After")
    }

    func testFileTreeOrdersDirectoriesFirstAndExcludesGitMetadata() async throws {
        try FileManager.default.createDirectory(at: root.appendingPathComponent("Sources"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: root.appendingPathComponent(".git"), withIntermediateDirectories: true)
        try "text".write(to: root.appendingPathComponent("README.md"), atomically: true, encoding: .utf8)

        let nodes = try await WorkspaceFileService().fileTree(at: root)

        XCTAssertEqual(nodes.map(\.name), ["Sources", "README.md"])
        XCTAssertTrue(nodes[0].isDirectory)
    }

    func testDiscoversGlobalInstructionFilesFromConfiguredHome() async throws {
        let fakeHome = root.appendingPathComponent("fake-home", isDirectory: true)
        let claudeDir = fakeHome.appendingPathComponent(".claude", isDirectory: true)
        let agentsDir = fakeHome.appendingPathComponent(".agents", isDirectory: true)
        try FileManager.default.createDirectory(at: claudeDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: agentsDir, withIntermediateDirectories: true)

        try "# Global Claude".write(to: claudeDir.appendingPathComponent("CLAUDE.md"), atomically: true, encoding: .utf8)
        try "# Global Agents".write(to: agentsDir.appendingPathComponent("AGENTS.md"), atomically: true, encoding: .utf8)

        let service = WorkspaceFileService(homeDirectoryProvider: { fakeHome })
        let entries = try await service.globalInstructionFiles()

        XCTAssertEqual(entries.count, 2)
        XCTAssertEqual(entries.map(\.relativePath), ["~/.agents/AGENTS.md", "~/.claude/CLAUDE.md"])
        XCTAssertTrue(entries.allSatisfy { $0.scope == .global })
    }
}

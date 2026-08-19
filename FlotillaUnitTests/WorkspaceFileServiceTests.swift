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

    func testDiscoversSkillsAcrossGlobalAndProjectScopesWithPluginAttribution() async throws {
        let fakeHome = root.appendingPathComponent("fake-home", isDirectory: true)
        let projectDir = root.appendingPathComponent("project", isDirectory: true)

        // 1. Global skill in ~/.claude/skills/review
        let globalSkillDir = fakeHome.appendingPathComponent(".claude/skills/review", isDirectory: true)
        try FileManager.default.createDirectory(at: globalSkillDir, withIntermediateDirectories: true)
        let globalSkillText = "---\nname: code-review\ndescription: Global review skill\n---\nBody"
        try globalSkillText.write(to: globalSkillDir.appendingPathComponent("SKILL.md"), atomically: true, encoding: .utf8)

        // 2. Global plugin skill in ~/.claude/plugins/formatter-plugin/skills/fmt
        let pluginSkillDir = fakeHome.appendingPathComponent(".claude/plugins/formatter-plugin/skills/fmt", isDirectory: true)
        try FileManager.default.createDirectory(at: pluginSkillDir, withIntermediateDirectories: true)
        let pluginSkillText = "---\nname: code-fmt\ndescription: Formats code\n---\nBody"
        try pluginSkillText.write(to: pluginSkillDir.appendingPathComponent("SKILL.md"), atomically: true, encoding: .utf8)

        // 3. Project skill in <projectRoot>/.agents/skills/deploy
        let projectSkillDir = projectDir.appendingPathComponent(".agents/skills/deploy", isDirectory: true)
        try FileManager.default.createDirectory(at: projectSkillDir, withIntermediateDirectories: true)
        let projectSkillText = "---\nname: project-deploy\ndescription: Deploys project\n---\nBody"
        try projectSkillText.write(to: projectSkillDir.appendingPathComponent("SKILL.md"), atomically: true, encoding: .utf8)

        let service = WorkspaceFileService(homeDirectoryProvider: { fakeHome })
        let skills = try await service.skills(projectRoot: projectDir)

        XCTAssertEqual(skills.count, 3)

        let fmtSkill = skills.first { $0.name == "code-fmt" }
        XCTAssertNotNil(fmtSkill)
        XCTAssertEqual(fmtSkill?.scope, .global)
        XCTAssertEqual(fmtSkill?.source, "formatter-plugin")

        let reviewSkill = skills.first { $0.name == "code-review" }
        XCTAssertNotNil(reviewSkill)
        XCTAssertEqual(reviewSkill?.scope, .global)
        XCTAssertNil(reviewSkill?.source)

        let deploySkill = skills.first { $0.name == "project-deploy" }
        XCTAssertNotNil(deploySkill)
        XCTAssertEqual(deploySkill?.scope, .project)
    }
}

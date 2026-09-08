import XCTest
@testable import Flotilla

/// The Skills and Rules tabs now run through one view model, so these cover the
/// two behaviours that used to be duplicated per tab: which scan `load()` does
/// for each kind, and the scope-plus-search filtering the designs render.
@MainActor
final class ProjectKnowledgeViewModelTests: XCTestCase {

    private let root = URL(fileURLWithPath: "/tmp/proj")

    // MARK: - Loading

    func testSkillsKindLoadsSkillsAndIgnoresInstructionFiles() async {
        let service = StubWorkspaceFileService()
        service.skillsToReturn = [skill(name: "review"), skill(name: "deploy")]
        service.projectRulesToReturn = [rule("CLAUDE.md")]

        let viewModel = ProjectKnowledgeViewModel(kind: .skills, projectRoot: root, service: service)
        await viewModel.load()

        XCTAssertEqual(viewModel.items.map(\.title), ["review", "deploy"])
        XCTAssertEqual(service.instructionFilesCallCount, 0)
    }

    func testRulesKindMergesGlobalsAheadOfProjectFiles() async {
        let service = StubWorkspaceFileService()
        service.globalRulesToReturn = [rule("~/.claude/CLAUDE.md", scope: .global)]
        service.projectRulesToReturn = [rule("AGENTS.md"), rule("CLAUDE.md")]

        let viewModel = ProjectKnowledgeViewModel(kind: .rules, projectRoot: root, service: service)
        await viewModel.load()

        XCTAssertEqual(
            viewModel.items.map(\.title),
            ["~/.claude/CLAUDE.md", "AGENTS.md", "CLAUDE.md"],
            "globals come first, as this tab has always shown them"
        )
        XCTAssertEqual(service.skillsCallCount, 0)
    }

    func testLoadFailureClearsItemsAndSurfacesTheMessage() async {
        let service = StubWorkspaceFileService()
        service.skillsToReturn = [skill(name: "review")]
        let viewModel = ProjectKnowledgeViewModel(kind: .skills, projectRoot: root, service: service)
        await viewModel.load()
        XCTAssertEqual(viewModel.items.count, 1)

        service.errorToThrow = StubError.boom
        await viewModel.load()

        XCTAssertTrue(viewModel.items.isEmpty)
        XCTAssertNotNil(viewModel.message)
    }

    // MARK: - Filtering

    func testScopeFilterNarrowsToGlobalOrProject() async {
        let viewModel = await loadedSkillsViewModel([
            skill(name: "global-one", scope: .global),
            skill(name: "project-one", scope: .project),
        ])

        viewModel.filter = .all
        XCTAssertEqual(viewModel.filteredItems.count, 2)

        viewModel.filter = .global
        XCTAssertEqual(viewModel.filteredItems.map(\.title), ["global-one"])

        viewModel.filter = .project
        XCTAssertEqual(viewModel.filteredItems.map(\.title), ["project-one"])
    }

    func testSearchAndScopeFilterCompose() async {
        let viewModel = await loadedSkillsViewModel([
            skill(name: "review", scope: .global),
            skill(name: "review-local", scope: .project),
            skill(name: "deploy", scope: .project),
        ])

        viewModel.filter = .project
        viewModel.searchText = "review"

        XCTAssertEqual(viewModel.filteredItems.map(\.title), ["review-local"])
    }

    func testBlankSearchIsNotAFilter() async {
        let viewModel = await loadedSkillsViewModel([skill(name: "review"), skill(name: "deploy")])

        viewModel.searchText = "   "
        XCTAssertEqual(viewModel.filteredItems.count, 2)
    }

    // MARK: - Sorting

    func testDefaultSortIsAlphabetical() async {
        let viewModel = await loadedSkillsViewModel([
            skill(name: "zeta"), skill(name: "alpha"), skill(name: "Mid"),
        ])

        XCTAssertEqual(viewModel.sort, .name)
        XCTAssertEqual(viewModel.filteredItems.map(\.title), ["alpha", "Mid", "zeta"])
    }

    func testSortByNameIsCaseInsensitiveAndNumberAware() async {
        let viewModel = await loadedSkillsViewModel([
            skill(name: "step-10"), skill(name: "step-2"),
        ])

        XCTAssertEqual(
            viewModel.filteredItems.map(\.title),
            ["step-2", "step-10"],
            "localizedStandardCompare orders embedded numbers naturally"
        )
    }

    func testSortByModifiedPutsNewestFirstAndUndatedItemsLast() {
        let now = Date()
        let older = item(title: "older", modified: now.addingTimeInterval(-3600))
        let newer = item(title: "newer", modified: now)
        let undated = item(title: "undated", modified: nil)

        let sorted = [older, undated, newer].sorted(by: KnowledgeSort.modified.areInIncreasingOrder)

        XCTAssertEqual(sorted.map(\.title), ["newer", "older", "undated"])
    }

    func testSortBySizePutsLargestFirst() {
        let sorted = [
            item(title: "small", bytes: 10),
            item(title: "big", bytes: 9000),
            item(title: "mid", bytes: 500),
        ].sorted(by: KnowledgeSort.size.areInIncreasingOrder)

        XCTAssertEqual(sorted.map(\.title), ["big", "mid", "small"])
    }

    func testEqualSizesFallBackToNameSoOrderIsStable() {
        let sorted = [
            item(title: "beta", bytes: 100),
            item(title: "alpha", bytes: 100),
        ].sorted(by: KnowledgeSort.size.areInIncreasingOrder)

        XCTAssertEqual(sorted.map(\.title), ["alpha", "beta"])
    }

    func testSortAppliesAfterFilteringNotBeforeIt() async {
        let viewModel = await loadedSkillsViewModel([
            skill(name: "zeta", scope: .global),
            skill(name: "alpha", scope: .project),
            skill(name: "beta", scope: .project),
        ])
        viewModel.filter = .project

        XCTAssertEqual(viewModel.filteredItems.map(\.title), ["alpha", "beta"])
    }

    // MARK: - Editing

    func testSelectLoadsFileContents() async {
        let service = StubWorkspaceFileService()
        service.skillsToReturn = [skill(name: "review")]
        service.textToReturn = "# Review"
        let viewModel = ProjectKnowledgeViewModel(kind: .skills, projectRoot: root, service: service)
        await viewModel.load()

        await viewModel.select(viewModel.items[0])

        XCTAssertEqual(viewModel.content, "# Review")
        XCTAssertEqual(viewModel.selected?.title, "review")
    }

    func testDeselectClearsSelectionAndContent() async {
        let service = StubWorkspaceFileService()
        service.skillsToReturn = [skill(name: "review")]
        service.textToReturn = "# Review"
        let viewModel = ProjectKnowledgeViewModel(kind: .skills, projectRoot: root, service: service)
        await viewModel.load()
        await viewModel.select(viewModel.items[0])

        viewModel.deselect()

        XCTAssertNil(viewModel.selected)
        XCTAssertTrue(viewModel.content.isEmpty)
    }

    func testSaveWithNothingSelectedIsANoOp() async {
        let service = StubWorkspaceFileService()
        let viewModel = ProjectKnowledgeViewModel(kind: .rules, projectRoot: root, service: service)

        await viewModel.save()

        XCTAssertEqual(service.writtenText.count, 0)
    }

    func testSaveWritesTheEditedContent() async {
        let service = StubWorkspaceFileService()
        service.skillsToReturn = [skill(name: "review")]
        service.textToReturn = "# Review"
        let viewModel = ProjectKnowledgeViewModel(kind: .skills, projectRoot: root, service: service)
        await viewModel.load()
        await viewModel.select(viewModel.items[0])

        viewModel.content = "# Edited"
        await viewModel.save()

        XCTAssertEqual(service.writtenText.last, "# Edited")
        XCTAssertEqual(viewModel.message, "Saved")
    }

    // MARK: - Templates

    func testCreateTemplateWritesTheFileAndReportsItAsNew() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let service = StubWorkspaceFileService()
        let viewModel = ProjectKnowledgeViewModel(kind: .rules, projectRoot: directory, service: service)

        let didCreate = await viewModel.createTemplate(named: "CLAUDE.md", content: "# Rules")

        XCTAssertTrue(didCreate)
        let written = try String(contentsOf: directory.appendingPathComponent("CLAUDE.md"), encoding: .utf8)
        XCTAssertEqual(written, "# Rules")
    }

    func testCreateTemplateNeverOverwritesAnExistingFile() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let target = directory.appendingPathComponent("CLAUDE.md")
        try "# Mine".write(to: target, atomically: true, encoding: .utf8)

        let service = StubWorkspaceFileService()
        let viewModel = ProjectKnowledgeViewModel(kind: .rules, projectRoot: directory, service: service)

        let didCreate = await viewModel.createTemplate(named: "CLAUDE.md", content: "# Template")

        XCTAssertFalse(didCreate, "an existing file is opened, not replaced")
        let written = try String(contentsOf: target, encoding: .utf8)
        XCTAssertEqual(written, "# Mine")
    }

    // MARK: - Helpers

    private func loadedSkillsViewModel(_ skills: [SkillEntry]) async -> ProjectKnowledgeViewModel {
        let service = StubWorkspaceFileService()
        service.skillsToReturn = skills
        let viewModel = ProjectKnowledgeViewModel(kind: .skills, projectRoot: root, service: service)
        await viewModel.load()
        return viewModel
    }

    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("KnowledgeTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func item(title: String, bytes: Int = 0, modified: Date? = nil) -> KnowledgeItem {
        KnowledgeItem(
            url: URL(fileURLWithPath: "/tmp/proj/\(title).md"),
            kind: .rules,
            title: title,
            subtitle: "",
            scope: .project,
            icon: .file(URL(fileURLWithPath: "/tmp/proj/\(title).md")),
            frameworkName: nil,
            framework: nil,
            source: nil,
            version: nil,
            invocation: nil,
            tags: [],
            metrics: [],
            author: nil,
            license: nil,
            weight: 0,
            byteSize: bytes,
            lastModified: modified,
            parentFolder: "proj"
        )
    }

    private func skill(name: String, scope: SkillScope = .project) -> SkillEntry {
        SkillEntry(
            url: URL(fileURLWithPath: "/tmp/proj/.claude/skills/\(name)/SKILL.md"),
            name: name,
            description: "Does \(name).",
            scope: scope
        )
    }

    private func rule(_ path: String, scope: RuleScope = .project) -> RuleFileEntry {
        RuleFileEntry(
            url: URL(fileURLWithPath: "/tmp/proj/\(path)"),
            relativePath: path,
            scope: scope
        )
    }
}

private enum StubError: Error { case boom }

/// Records which scans were asked for, so a test can assert that the Skills
/// tab doesn't scan for rules and vice versa.
private final class StubWorkspaceFileService: WorkspaceFileServicing, @unchecked Sendable {
    var skillsToReturn: [SkillEntry] = []
    var projectRulesToReturn: [RuleFileEntry] = []
    var globalRulesToReturn: [RuleFileEntry] = []
    var textToReturn = ""
    var errorToThrow: Error?

    private(set) var skillsCallCount = 0
    private(set) var instructionFilesCallCount = 0
    private(set) var writtenText: [String] = []

    func metadata(at url: URL) async -> WorkspaceFileMetadata {
        WorkspaceFileMetadata(size: nil, modificationDate: nil)
    }

    func fileTree(at root: URL) async throws -> [FileNode] { [] }

    func instructionFiles(in root: URL) async throws -> [RuleFileEntry] {
        instructionFilesCallCount += 1
        if let errorToThrow { throw errorToThrow }
        return projectRulesToReturn
    }

    func globalInstructionFiles() async throws -> [RuleFileEntry] {
        if let errorToThrow { throw errorToThrow }
        return globalRulesToReturn
    }

    func skills(projectRoot: URL) async throws -> [SkillEntry] {
        skillsCallCount += 1
        if let errorToThrow { throw errorToThrow }
        return skillsToReturn
    }

    func readText(at url: URL) async throws -> String {
        if let errorToThrow { throw errorToThrow }
        return textToReturn
    }

    func writeText(_ text: String, to url: URL) async throws {
        if let errorToThrow { throw errorToThrow }
        writtenText.append(text)
    }
}

import XCTest
import SessionKit
@testable import Flotilla

/// `SessionLaunchPreview` is what the launcher promises the user *before* a
/// session exists. These tests pin it to the same `BranchNaming` /
/// `WorktreePlanner` behaviour `AppStore.createSession` uses, so the preview
/// cannot quietly drift from what actually happens.
final class SessionLaunchPreviewTests: XCTestCase {
    private let worktreeBase = URL(fileURLWithPath: "/tmp/flotilla-worktrees", isDirectory: true)
    private let generalDirectory = URL(fileURLWithPath: "/tmp/flotilla-general", isDirectory: true)
    private let projectRoot = URL(fileURLWithPath: "/Users/dev/Repos/flotilla", isDirectory: true)

    private func resolve(
        goal: String,
        choice: ProjectChoice,
        agent: AgentKind = .claudeCode,
        model: String? = nil,
        effort: AgentEffort? = nil,
        createWorktree: Bool
    ) -> SessionLaunchPreview {
        SessionLaunchPreview.resolve(
            goal: goal,
            projectChoice: choice,
            agent: agent,
            model: model,
            effort: effort,
            createWorktree: createWorktree,
            worktreeBaseDirectory: worktreeBase,
            generalSessionDirectory: generalDirectory
        )
    }

    private func project(named name: String = "flotilla") -> Project {
        Project(name: name, rootPath: projectRoot)
    }

    // MARK: - Working directory

    func testGeneralSessionUsesGeneralDirectoryAndHasNoBranch() {
        let preview = resolve(goal: "Look something up", choice: .general, createWorktree: true)

        XCTAssertNil(preview.branchSlug)
        XCTAssertFalse(preview.isWorktree)
        XCTAssertEqual(preview.workingDirectory, generalDirectory)
        XCTAssertNil(preview.sharedCheckoutWarning)
    }

    func testMainCheckoutUsesProjectRootAndWarnsAboutSharing() {
        let preview = resolve(goal: "Dark mode", choice: .known(project()), createWorktree: false)

        XCTAssertNil(preview.branchSlug)
        XCTAssertEqual(preview.workingDirectory, projectRoot)
        XCTAssertNotNil(preview.sharedCheckoutWarning, "A shared checkout must state that concurrent sessions can conflict")
    }

    func testWorktreeDestinationLivesUnderTheConfiguredBaseDirectory() {
        let preview = resolve(goal: "Dark mode", choice: .known(project()), createWorktree: true)

        XCTAssertTrue(preview.isWorktree)
        XCTAssertTrue(
            preview.workingDirectory.path.hasPrefix(worktreeBase.path),
            "Expected \(preview.workingDirectory.path) under \(worktreeBase.path)"
        )
        XCTAssertNil(preview.sharedCheckoutWarning)
    }

    func testCustomFolderBehavesLikeAKnownProject() {
        let folder = URL(fileURLWithPath: "/Users/dev/Scratch/spike", isDirectory: true)
        let preview = resolve(goal: "", choice: .custom(folder), createWorktree: false)

        XCTAssertEqual(preview.workingDirectory, folder)
        XCTAssertEqual(preview.title, "spike", "An empty goal falls back to the folder name")
    }

    // MARK: - Branch naming

    func testBranchSlugMatchesBranchNamingWithoutTheRandomSuffix() {
        let preview = resolve(goal: "Dark mode", choice: .known(project()), createWorktree: true)

        // BranchNaming appends a per-launch random 8-hex suffix; only the
        // stable slug can be previewed.
        XCTAssertEqual(preview.branchSlug, "flotilla/dark-mode")
    }

    func testBranchSlugSlugifiesPunctuationTheSameWayBranchNamingDoes() {
        let goal = "Fix the CI/CD pipeline (again!)"
        let preview = resolve(goal: goal, choice: .known(project()), createWorktree: true)

        let expected = BranchNaming.generate(from: goal, uuid: UUID())
        XCTAssertTrue(
            expected.hasPrefix(preview.branchSlug ?? "<none>"),
            "\(expected) should start with the previewed slug \(preview.branchSlug ?? "<none>")"
        )
    }

    func testDisplayBranchMarksTheSuffixAsUnknownRatherThanInventingOne() {
        let preview = resolve(goal: "Dark mode", choice: .known(project()), createWorktree: true)

        let displayed = try? XCTUnwrap(preview.displayBranch)
        XCTAssertEqual(displayed, "flotilla/dark-mode-••••••••")
    }

    // MARK: - Title derivation

    func testTitleTruncatesLongGoalsToSixtyCharacters() {
        let goal = String(repeating: "a", count: 120)
        let preview = resolve(goal: goal, choice: .general, createWorktree: false)

        XCTAssertEqual(preview.title.count, 60)
    }

    func testEmptyGoalFallsBackToProjectNameThenGeneralSession() {
        let projectPreview = resolve(goal: "   ", choice: .known(project(named: "Atlas")), createWorktree: false)
        XCTAssertEqual(projectPreview.title, "Atlas")

        let generalPreview = resolve(goal: "", choice: .general, createWorktree: false)
        XCTAssertEqual(generalPreview.title, "General session")
    }

    // MARK: - Command rendering

    func testCommandShowsTheBinaryAloneWhenModelAndEffortAreDefaulted() {
        let preview = resolve(goal: "Anything", choice: .general, agent: .claudeCode, createWorktree: false)

        XCTAssertEqual(preview.command, "claude")
    }

    func testCommandIncludesResolvedModelAndEffortFlags() {
        let preview = resolve(
            goal: "Anything",
            choice: .general,
            agent: .claudeCode,
            model: "opus",
            effort: .high,
            createWorktree: false
        )

        XCTAssertTrue(preview.command.hasPrefix("claude "))
        XCTAssertTrue(preview.command.contains("opus"), preview.command)
        XCTAssertTrue(preview.command.contains("high"), preview.command)
    }

    func testCommandOmitsEffortForAgentsThatHaveNoEffortFlag() {
        let preview = resolve(
            goal: "Anything",
            choice: .general,
            agent: .openCode,
            effort: .high,
            createWorktree: false
        )

        XCTAssertFalse(
            preview.command.contains("high"),
            "OpenCode exposes no effort knob — \(preview.command) must not imply one"
        )
    }

    // MARK: - Path display

    func testDisplayDirectoryAbbreviatesTheHomePrefix() {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let folder = home.appendingPathComponent("Repos/thing", isDirectory: true)
        let preview = resolve(goal: "x", choice: .custom(folder), createWorktree: false)

        XCTAssertEqual(preview.displayDirectory, "~/Repos/thing")
    }
}

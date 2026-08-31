import XCTest
import GitKit
import SessionKit
@testable import Flotilla

@MainActor
final class SessionGitSidebarViewModelTests: XCTestCase {
    private let repoPath = URL(fileURLWithPath: "/tmp/flotilla-git-sidebar-tests")

    private func session(projectID: UUID? = UUID()) -> Session {
        Session(
            id: UUID(),
            title: "Git sidebar",
            goal: "Review changes",
            agent: .codexCLI,
            projectID: projectID,
            workingDirectory: repoPath
        )
    }

    private func diff(
        _ path: String,
        stage: FileDiff.Stage,
        lines: [String]
    ) -> FileDiff {
        FileDiff(
            path: path,
            hunks: [FileDiffHunk(header: "@@ -1 +1 @@", lines: lines)],
            stage: stage
        )
    }

    func testUncommittedChangesCombinePartialStageStateAndStats() async throws {
        let git = MockGitService()
        git.statusToReturn = GitStatus(entries: [
            GitStatusEntry(path: "Sources/App.swift", indexStatus: "M", worktreeStatus: "M")
        ])
        git.stagedDiffToReturn = [diff("Sources/App.swift", stage: .staged, lines: ["-old", "+staged"])]
        git.unstagedDiffToReturn = [diff("Sources/App.swift", stage: .unstaged, lines: ["+working"])]
        let viewModel = SessionGitSidebarViewModel(session: session(), gitService: git)

        await viewModel.refreshSelection()

        let item = try XCTUnwrap(viewModel.changes.first)
        XCTAssertEqual(item.path, "Sources/App.swift")
        XCTAssertEqual(item.filename, "App.swift")
        XCTAssertEqual(item.directory, "Sources")
        XCTAssertEqual(item.kind, .modified)
        XCTAssertEqual(item.stageState, .partiallyStaged)
        XCTAssertEqual(item.stat, GitDiffStat(additions: 2, deletions: 1))
        XCTAssertEqual(viewModel.selectedFileCount, 1)
    }

    func testToggleStageStagesUnstagedFileAndUnstagesSelectedFile() async throws {
        let git = MockGitService()
        git.statusToReturn = GitStatus(entries: [
            GitStatusEntry(path: "One.swift", indexStatus: " ", worktreeStatus: "M")
        ])
        git.unstagedDiffToReturn = [diff("One.swift", stage: .unstaged, lines: ["+one"])]
        let viewModel = SessionGitSidebarViewModel(session: session(), gitService: git)
        await viewModel.refreshSelection()

        await viewModel.toggleStage(for: try XCTUnwrap(viewModel.changes.first))
        XCTAssertEqual(git.stageCalls.first?.paths, ["One.swift"])

        git.statusToReturn = GitStatus(entries: [
            GitStatusEntry(path: "Two.swift", indexStatus: "M", worktreeStatus: " ")
        ])
        git.unstagedDiffToReturn = []
        git.stagedDiffToReturn = [diff("Two.swift", stage: .staged, lines: ["+two"])]
        await viewModel.refreshChanges()

        await viewModel.toggleStage(for: try XCTUnwrap(viewModel.changes.first))
        XCTAssertEqual(git.unstageCalls.first?.paths, ["Two.swift"])
    }

    func testCommitUsesSelectedFilesAndClearsMessage() async {
        let git = MockGitService()
        git.statusToReturn = GitStatus(entries: [
            GitStatusEntry(path: "README.md", indexStatus: "M", worktreeStatus: " ")
        ])
        git.stagedDiffToReturn = [diff("README.md", stage: .staged, lines: ["+new"])]
        let viewModel = SessionGitSidebarViewModel(session: session(), gitService: git)
        await viewModel.refreshSelection()
        viewModel.commitMessage = "  Explain the change  "

        await viewModel.commit()

        XCTAssertEqual(git.commitCalls.first?.message, "Explain the change")
        XCTAssertEqual(viewModel.commitMessage, "")
    }

    func testVersusDefaultLoadsReadOnlyComparison() async throws {
        let git = MockGitService()
        git.defaultBranchToReturn = "develop"
        git.comparisonChangesToReturn = [
            GitCommitFileChange(
                path: "Feature.swift",
                kind: .added,
                hunks: [FileDiffHunk(header: "@@", lines: ["+feature"])]
            )
        ]
        let viewModel = SessionGitSidebarViewModel(session: session(), gitService: git)
        viewModel.changeMode = .versusDefault

        await viewModel.refreshSelection()

        XCTAssertEqual(git.comparisonCalls.first?.base, "develop")
        let item = try XCTUnwrap(viewModel.changes.first)
        XCTAssertEqual(item.kind, .added)
        XCTAssertNil(item.stageState)
        XCTAssertEqual(item.stat.additions, 1)
    }

    func testBranchesAreLocalCurrentFirstThenNewestCommit() async {
        let git = MockGitService()
        git.branchToReturn = "main"
        git.branchesToReturn = [
            GitBranch(name: "older", isCurrent: false, isRemote: false, tipSHA: "1", lastCommitDate: Date(timeIntervalSince1970: 10)),
            GitBranch(name: "origin/main", isCurrent: false, isRemote: true, tipSHA: "2", lastCommitDate: Date(timeIntervalSince1970: 40)),
            GitBranch(name: "newer", isCurrent: false, isRemote: false, tipSHA: "3", lastCommitDate: Date(timeIntervalSince1970: 30)),
            GitBranch(name: "main", isCurrent: true, isRemote: false, tipSHA: "4", lastCommitDate: Date(timeIntervalSince1970: 5))
        ]
        let viewModel = SessionGitSidebarViewModel(session: session(), gitService: git)
        viewModel.selectedTab = .branches

        await viewModel.refreshSelection()

        XCTAssertEqual(viewModel.branches.map(\.name), ["main", "newer", "older"])
    }

    func testDirtyTreeBlocksCheckout() async {
        let git = MockGitService()
        git.statusToReturn = GitStatus(entries: [
            GitStatusEntry(path: "Dirty.swift", indexStatus: " ", worktreeStatus: "M")
        ])
        let viewModel = SessionGitSidebarViewModel(session: session(), gitService: git)
        await viewModel.refreshSelection()

        let didCheckout = await viewModel.checkout("feature")

        XCTAssertFalse(didCheckout)
        XCTAssertTrue(git.checkoutCalls.isEmpty)
        XCTAssertEqual(
            viewModel.actionErrorMessage,
            "Commit or discard uncommitted changes before switching branches."
        )
    }

    func testCleanTreeCreatesAndChecksOutTrimmedBranchName() async {
        let git = MockGitService()
        let viewModel = SessionGitSidebarViewModel(session: session(), gitService: git)
        await viewModel.refreshSelection()

        let branch = await viewModel.createAndCheckoutBranch(named: "  feature/sidebar  ")

        XCTAssertEqual(branch, "feature/sidebar")
        XCTAssertEqual(git.createBranchCalls.first?.branch, "feature/sidebar")
        XCTAssertEqual(viewModel.currentBranch, "feature/sidebar")
    }

    func testViewCommitsSwitchesToFilteredLog() async {
        let git = MockGitService()
        git.branchesToReturn = [
            GitBranch(name: "feature", isCurrent: false, isRemote: false, tipSHA: "abc")
        ]
        let viewModel = SessionGitSidebarViewModel(session: session(), gitService: git)

        viewModel.showCommits(for: "feature")
        await viewModel.refreshSelection()

        XCTAssertEqual(viewModel.selectedTab, .log)
        XCTAssertEqual(viewModel.selectedLogBranch, "feature")
        XCTAssertEqual(git.logCalls.first?.ref, "feature")
    }
}

@MainActor
final class SessionGitSidebarNavigationTests: XCTestCase {
    func testCommitOpensExactProjectGraphSelection() {
        let projectID = UUID()
        let repoPath = URL(fileURLWithPath: "/tmp/flotilla-sidebar-navigation")
        let session = Session(
            title: "Git sidebar",
            goal: "Inspect a commit",
            agent: .codexCLI,
            projectID: projectID,
            workingDirectory: repoPath
        )
        let commit = GitCommit(
            sha: "abcdef1234567890",
            shortSHA: "abcdef1",
            parents: [],
            authorName: "Flotilla",
            authorEmail: "test@example.com",
            authorDate: .now,
            committerName: "Flotilla",
            committerEmail: "test@example.com",
            committerDate: .now,
            refs: [],
            subject: "Add sidebar",
            body: "",
            stat: GitDiffStat(additions: 10, deletions: 2),
            changedFileCount: 2
        )
        let git = MockGitService()
        let navigator = WorkspaceNavigator()

        navigator.openProjectCommit(commit, branch: "feature/sidebar", scopedTo: session, gitService: git)

        XCTAssertEqual(navigator.selection, .project(projectID))
        XCTAssertEqual(navigator.projectTab(for: projectID), .git)
        XCTAssertEqual(navigator.projectGitSubTab(for: projectID), .commits)
        XCTAssertEqual(navigator.projectGitScope(for: projectID), repoPath.standardizedFileURL)
        let graph = navigator.projectGraphViewModel(for: repoPath, gitService: git)
        XCTAssertEqual(graph.selectedBranchFilter, "feature/sidebar")
        XCTAssertEqual(graph.selectedSHA, commit.sha)
    }

    func testSidebarViewModelIsReusedForTheSameCheckout() {
        let repoPath = URL(fileURLWithPath: "/tmp/flotilla-sidebar-reuse")
        let firstSession = Session(
            title: "First",
            goal: "Review",
            agent: .codexCLI,
            projectID: nil,
            workingDirectory: repoPath
        )
        let secondSession = Session(
            title: "Second",
            goal: "Review again",
            agent: .claudeCode,
            projectID: nil,
            workingDirectory: repoPath
        )
        let navigator = WorkspaceNavigator()

        let first = navigator.sessionGitSidebarViewModel(for: firstSession, gitService: MockGitService())
        let second = navigator.sessionGitSidebarViewModel(for: secondSession, gitService: MockGitService())

        XCTAssertTrue(first === second)
    }
}

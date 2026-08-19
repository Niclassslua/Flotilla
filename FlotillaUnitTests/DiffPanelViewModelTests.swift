import XCTest
import GitKit
import SessionKit
@testable import Flotilla

@MainActor
final class DiffPanelViewModelTests: XCTestCase {
    private func session() -> Session {
        Session(
            id: UUID(),
            title: "Repair build",
            goal: "Resolve every compiler error",
            agent: .claudeCode,
            projectID: nil,
            workingDirectory: URL(fileURLWithPath: "/tmp/flotilla-diff-tests")
        )
    }

    private func makeStagedSnapshot() -> GitChangesSnapshot {
        GitChangesSnapshot(
            status: GitStatus(entries: []),
            staged: [FileDiff(path: "README.md", hunks: [], stage: .staged)],
            unstaged: [],
            untracked: []
        )
    }

    func testCommitNoOpsWhenNothingIsStaged() async {
        let gitService = MockGitService()
        let viewModel = DiffPanelViewModel(session: session(), gitService: gitService)
        viewModel.commitMessage = "A message"

        await viewModel.commit()

        XCTAssertTrue(gitService.commitCalls.isEmpty)
    }

    func testCommitNoOpsWhenMessageIsBlank() async {
        let gitService = MockGitService()
        gitService.diffToReturn = []
        let viewModel = DiffPanelViewModel(session: session(), gitService: gitService)
        await viewModel.refresh()
        viewModel.commitMessage = "   "

        await viewModel.commit()

        XCTAssertTrue(gitService.commitCalls.isEmpty)
    }

    func testCommitCallsThroughAndClearsMessageOnSuccess() async {
        let gitService = MockGitService()
        gitService.statusToReturn = GitStatus(entries: [
            GitStatusEntry(path: "README.md", indexStatus: "M", worktreeStatus: " ")
        ])
        gitService.diffToReturn = [FileDiff(path: "README.md", hunks: [], stage: .staged)]
        let viewModel = DiffPanelViewModel(session: session(), gitService: gitService)
        await viewModel.refresh()
        viewModel.commitMessage = "Fix the build"

        await viewModel.commit()

        XCTAssertEqual(gitService.commitCalls.first?.message, "Fix the build")
        XCTAssertEqual(viewModel.commitMessage, "")
        XCTAssertNil(viewModel.actionErrorMessage)
    }

    func testCommitSetsActionErrorMessageOnFailureWithoutTouchingReadError() async {
        let gitService = MockGitService()
        gitService.statusToReturn = GitStatus(entries: [
            GitStatusEntry(path: "README.md", indexStatus: "M", worktreeStatus: " ")
        ])
        gitService.diffToReturn = [FileDiff(path: "README.md", hunks: [], stage: .staged)]
        let viewModel = DiffPanelViewModel(session: session(), gitService: gitService)
        await viewModel.refresh()
        viewModel.commitMessage = "Fix the build"
        gitService.errorToThrow = GitServiceError.nothingToCommit

        await viewModel.commit()

        XCTAssertEqual(viewModel.actionErrorMessage, GitServiceError.nothingToCommit.localizedDescription)
        XCTAssertNil(viewModel.errorMessage)
    }

    func testStageRefreshesSnapshotAfterSuccess() async {
        let gitService = MockGitService()
        let entry = FileDiff(path: "README.md", hunks: [], stage: .unstaged)
        let viewModel = DiffPanelViewModel(session: session(), gitService: gitService)

        await viewModel.stage(entry)

        XCTAssertEqual(gitService.stageCalls.first?.paths, ["README.md"])
    }

    func testIsGhAvailableReflectsInjectedService() {
        let withGh = DiffPanelViewModel(session: session(), gitService: MockGitService(), ghService: MockGhService())
        XCTAssertTrue(withGh.isGhAvailable)

        let withoutGh = DiffPanelViewModel(session: session(), gitService: MockGitService())
        XCTAssertFalse(withoutGh.isGhAvailable)
    }

    func testCreatePullRequestNoOpsWhenGhUnavailable() async {
        let viewModel = DiffPanelViewModel(session: session(), gitService: MockGitService())

        await viewModel.createPullRequest()

        XCTAssertNil(viewModel.lastPullRequestURL)
    }

    func testCreatePullRequestStoresURLOnSuccess() async {
        let ghService = MockGhService()
        ghService.urlToReturn = URL(string: "https://github.com/example/example/pull/7")!
        let viewModel = DiffPanelViewModel(session: session(), gitService: MockGitService(), ghService: ghService)

        await viewModel.createPullRequest()

        XCTAssertEqual(viewModel.lastPullRequestURL?.absoluteString, "https://github.com/example/example/pull/7")
        XCTAssertEqual(ghService.createPullRequestCalls.count, 1)
    }
}

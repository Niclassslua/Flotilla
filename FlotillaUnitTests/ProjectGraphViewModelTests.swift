import XCTest
import GitKit
import SessionKit
@testable import Flotilla

@MainActor
final class ProjectGraphViewModelTests: XCTestCase {
    private let repoPath = URL(fileURLWithPath: "/tmp/flotilla-graph-tests")

    private func commit(
        sha: String,
        subject: String = "test commit",
        refs: [GitCommitRef] = []
    ) -> GitCommit {
        GitCommit(
            sha: sha,
            shortSHA: String(sha.prefix(7)),
            parents: [],
            authorName: "Tester",
            authorEmail: "test@example.com",
            authorDate: Date(),
            committerName: "Tester",
            committerEmail: "test@example.com",
            committerDate: Date(),
            refs: refs,
            subject: subject,
            body: "",
            stat: GitDiffStat(additions: 1, deletions: 0),
            changedFileCount: 1
        )
    }

    func testReloadPopulatesRowsAndBranches() async {
        let service = MockGitService()
        service.graphLogToReturn = [
            commit(sha: "sha1", subject: "First commit"),
            commit(sha: "sha2", subject: "Second commit")
        ]
        service.branchesToReturn = [
            GitBranch(name: "main", isCurrent: true, isRemote: false, tipSHA: "sha1"),
            GitBranch(name: "feature", isCurrent: false, isRemote: false, tipSHA: "sha2")
        ]

        let viewModel = ProjectGraphViewModel(repoPath: repoPath, gitService: service)
        await viewModel.reload()

        XCTAssertEqual(viewModel.rows.count, 2)
        XCTAssertEqual(viewModel.branches.count, 2)
        XCTAssertEqual(viewModel.selectedSHA, "sha1")
        XCTAssertNil(viewModel.errorMessage)
        XCTAssertEqual(service.logGraphCalls.count, 1)
        XCTAssertEqual(service.branchesCalls.count, 1)
    }

    func testBranchFilteringFiltersRows() async {
        let service = MockGitService()
        let refMain = GitCommitRef(name: "main", kind: .localBranch)
        let refFeature = GitCommitRef(name: "feature", kind: .localBranch)

        service.graphLogToReturn = [
            commit(sha: "sha1", subject: "Main commit", refs: [refMain]),
            commit(sha: "sha2", subject: "Feature commit", refs: [refFeature])
        ]
        service.branchesToReturn = [
            GitBranch(name: "main", isCurrent: true, isRemote: false, tipSHA: "sha1"),
            GitBranch(name: "feature", isCurrent: false, isRemote: false, tipSHA: "sha2")
        ]

        let viewModel = ProjectGraphViewModel(repoPath: repoPath, gitService: service)
        await viewModel.reload()

        XCTAssertEqual(viewModel.filteredRows.count, 2)

        viewModel.selectedBranchFilter = "feature"
        XCTAssertEqual(viewModel.filteredRows.count, 1)
        XCTAssertEqual(viewModel.filteredRows.first?.commit.sha, "sha2")

        viewModel.selectedBranchFilter = nil
        XCTAssertEqual(viewModel.filteredRows.count, 2)
    }

    func testReloadSurfacesError() async {
        let service = MockGitService()
        service.errorToThrow = GitServiceError.commandFailed(exitCode: 128, stderr: "not a git repository")

        let viewModel = ProjectGraphViewModel(repoPath: repoPath, gitService: service)
        await viewModel.reload()

        XCTAssertTrue(viewModel.rows.isEmpty)
        XCTAssertTrue(viewModel.branches.isEmpty)
        XCTAssertNotNil(viewModel.errorMessage)
    }
}

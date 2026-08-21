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

    func testSearchQueryFiltersGraphRows() async {
        let service = MockGitService()
        service.graphLogToReturn = [
            commit(sha: "sha1", subject: "feat: add graph DAG"),
            commit(sha: "sha2", subject: "fix: solve memory leak"),
            commit(sha: "sha3", subject: "chore: update documentation")
        ]

        let viewModel = ProjectGraphViewModel(repoPath: repoPath, gitService: service)
        await viewModel.reload()

        XCTAssertEqual(viewModel.filteredRows.count, 3)
        XCTAssertFalse(viewModel.isSearching)

        viewModel.searchQuery = "graph"
        XCTAssertTrue(viewModel.isSearching)
        XCTAssertEqual(viewModel.filteredRows.count, 1)
        XCTAssertEqual(viewModel.filteredRows.first?.commit.sha, "sha1")

        viewModel.searchQuery = "leak"
        XCTAssertEqual(viewModel.filteredRows.count, 1)
        XCTAssertEqual(viewModel.filteredRows.first?.commit.sha, "sha2")

        viewModel.searchQuery = "nonexistent"
        XCTAssertTrue(viewModel.filteredRows.isEmpty)

        viewModel.searchQuery = ""
        XCTAssertEqual(viewModel.filteredRows.count, 3)
    }

    func testGroupedRowsCategorizesByRecencyAndMonthYear() async {
        let calendar = Calendar.current
        let startOfToday = calendar.startOfDay(for: Date())
        let ninetyDaysAgo = calendar.date(byAdding: .day, value: -90, to: startOfToday)!

        var commitToday = commit(sha: "c1", subject: "Today commit")
        var commitOlder = commit(sha: "c2", subject: "Older month commit")
        commitToday = GitCommit(
            sha: commitToday.sha, shortSHA: commitToday.shortSHA, parents: [],
            authorName: commitToday.authorName, authorEmail: commitToday.authorEmail,
            authorDate: Date(), committerName: commitToday.committerName,
            committerEmail: commitToday.committerEmail, committerDate: Date(),
            refs: [], subject: commitToday.subject, body: "",
            stat: commitToday.stat, changedFileCount: 1
        )
        commitOlder = GitCommit(
            sha: commitOlder.sha, shortSHA: commitOlder.shortSHA, parents: [],
            authorName: commitOlder.authorName, authorEmail: commitOlder.authorEmail,
            authorDate: ninetyDaysAgo, committerName: commitOlder.committerName,
            committerEmail: commitOlder.committerEmail, committerDate: ninetyDaysAgo,
            refs: [], subject: commitOlder.subject, body: "",
            stat: commitOlder.stat, changedFileCount: 1
        )

        let service = MockGitService()
        service.graphLogToReturn = [commitToday, commitOlder]

        let viewModel = ProjectGraphViewModel(repoPath: repoPath, gitService: service)
        await viewModel.reload()

        let grouped = viewModel.groupedRows
        XCTAssertEqual(grouped.count, 2)
        XCTAssertEqual(grouped.first?.group, .today)
        XCTAssertEqual(grouped.first?.rows.first?.commit.sha, "c1")
        if case .month = grouped.last?.group {
            XCTAssertEqual(grouped.last?.rows.first?.commit.sha, "c2")
        } else {
            XCTFail("Older commit should be categorized in a month group")
        }
    }

    func testWebURLReturnsGitHubLink() async {
        let service = MockGitService()
        service.graphLogToReturn = [commit(sha: "abc123456789")]
        service.remoteURLToReturn = "git@github.com:Niclassslua/Flotilla.git"

        let viewModel = ProjectGraphViewModel(repoPath: repoPath, gitService: service)
        await viewModel.reload()

        let url = viewModel.webURL(for: viewModel.commits[0])
        XCTAssertEqual(url?.absoluteString, "https://github.com/Niclassslua/Flotilla/commit/abc123456789")
    }
}

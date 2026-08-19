import XCTest
import GitKit
import SessionKit
@testable import Flotilla

@MainActor
final class ProjectHistoryViewModelTests: XCTestCase {
    private let repoPath = URL(fileURLWithPath: "/tmp/flotilla-history-tests")

    private func commit(
        sha: String,
        subject: String = "a change",
        body: String = "",
        author: String = "Niclassslua",
        email: String = "niclassslua@example.com",
        hoursAgo: Double = 1,
        date: Date? = nil,
        parents: [String] = ["parent"],
        stat: GitDiffStat = GitDiffStat(additions: 1, deletions: 0)
    ) -> GitCommit {
        let date = date ?? Date().addingTimeInterval(-hoursAgo * 3600)
        return GitCommit(
            sha: sha, shortSHA: String(sha.prefix(7)), parents: parents,
            authorName: author, authorEmail: email, authorDate: date,
            committerName: author, committerEmail: email, committerDate: date,
            refs: [], subject: subject, body: body,
            stat: stat, changedFileCount: 1
        )
    }

    private func makeViewModel(_ service: MockGitService) -> ProjectHistoryViewModel {
        ProjectHistoryViewModel(repoPath: repoPath, gitService: service)
    }

    // MARK: - Loading

    func testReloadPopulatesCommitsAndAutoSelectsTheNewest() async {
        let service = MockGitService()
        service.logToReturn = [commit(sha: "aaa1", subject: "newest"), commit(sha: "bbb2", subject: "older")]
        let viewModel = makeViewModel(service)

        await viewModel.reload()

        XCTAssertEqual(viewModel.commits.map(\.subject), ["newest", "older"])
        XCTAssertEqual(viewModel.selectedSHA, "aaa1", "the detail pane must never start empty")
        XCTAssertNil(viewModel.errorMessage)
    }

    func testReloadSurfacesErrorAndClearsCommits() async {
        let service = MockGitService()
        service.logToReturn = [commit(sha: "aaa1")]
        service.errorToThrow = GitServiceError.commandFailed(exitCode: 128, stderr: "not a git repository")
        let viewModel = makeViewModel(service)

        await viewModel.reload()

        XCTAssertTrue(viewModel.commits.isEmpty)
        XCTAssertFalse(viewModel.hasMore)
        XCTAssertNotNil(viewModel.errorMessage)
    }

    func testLoadIfNeededDoesNotRefetchWhenAlreadyLoaded() async {
        let service = MockGitService()
        service.logToReturn = [commit(sha: "aaa1")]
        let viewModel = makeViewModel(service)

        await viewModel.loadIfNeeded()
        let callsAfterFirst = service.logCalls.count
        await viewModel.loadIfNeeded()

        XCTAssertEqual(service.logCalls.count, callsAfterFirst)
    }

    // MARK: - Paging

    func testHasMoreIsFalseWhenAPartialPageComesBack() async {
        let service = MockGitService()
        service.logToReturn = [commit(sha: "aaa1"), commit(sha: "bbb2")]
        let viewModel = makeViewModel(service)

        await viewModel.reload()

        XCTAssertFalse(viewModel.hasMore, "a page shorter than the page size is the end of history")
    }

    func testLoadMoreAppendsTheNextPageWithoutDuplicating() async {
        let service = MockGitService()
        service.logToReturn = (0..<(ProjectHistoryViewModel.pageSize + 20)).map {
            commit(sha: "sha-\($0)", subject: "commit \($0)")
        }
        let viewModel = makeViewModel(service)

        await viewModel.reload()
        XCTAssertEqual(viewModel.commits.count, ProjectHistoryViewModel.pageSize)
        XCTAssertTrue(viewModel.hasMore)

        await viewModel.loadMore()

        XCTAssertEqual(viewModel.commits.count, ProjectHistoryViewModel.pageSize + 20)
        XCTAssertEqual(Set(viewModel.commits.map(\.sha)).count, viewModel.commits.count, "no duplicates")
        XCTAssertFalse(viewModel.hasMore)
    }

    func testLoadMoreIsSuppressedWhileSearching() async {
        let service = MockGitService()
        service.logToReturn = (0..<(ProjectHistoryViewModel.pageSize + 5)).map { commit(sha: "sha-\($0)") }
        let viewModel = makeViewModel(service)
        await viewModel.reload()
        let callsBefore = service.logCalls.count

        viewModel.searchQuery = "anything"
        await viewModel.loadMore()

        XCTAssertEqual(service.logCalls.count, callsBefore, "paging a filtered list would be misleading")
    }

    // MARK: - Filtering

    func testFilterMatchesSubjectAuthorAndSHAPrefix() async {
        let service = MockGitService()
        service.logToReturn = [
            commit(sha: "abc1234", subject: "fix(git): pipe race", author: "Niclassslua"),
            commit(sha: "def5678", subject: "docs: update readme", author: "Ada Lovelace", email: "ada@example.com"),
        ]
        let viewModel = makeViewModel(service)
        await viewModel.reload()

        viewModel.searchQuery = "pipe"
        XCTAssertEqual(viewModel.filteredCommits.map(\.sha), ["abc1234"])

        viewModel.searchQuery = "ada"
        XCTAssertEqual(viewModel.filteredCommits.map(\.sha), ["def5678"])

        viewModel.searchQuery = "abc12"
        XCTAssertEqual(viewModel.filteredCommits.map(\.sha), ["abc1234"])

        viewModel.searchQuery = "  "
        XCTAssertEqual(viewModel.filteredCommits.count, 2, "a blank query is not a filter")
        XCTAssertFalse(viewModel.isSearching)
    }

    func testFilterMatchesBody() async {
        let service = MockGitService()
        service.logToReturn = [commit(sha: "aaa1", subject: "chore", body: "Closes the flaky pipe collector")]
        let viewModel = makeViewModel(service)
        await viewModel.reload()

        viewModel.searchQuery = "flaky"
        XCTAssertEqual(viewModel.filteredCommits.count, 1)
    }

    // MARK: - Grouping

    /// Anchored to calendar boundaries rather than "N hours ago": a fixed
    /// offset lands in a different bucket depending on the time of day the
    /// suite runs (an hour before midnight is *yesterday*), which made this
    /// pass all afternoon and fail just after 00:00.
    func testCommitsAreBucketedByRecencyNewestFirst() async {
        let calendar = Calendar.current
        let startOfToday = calendar.startOfDay(for: Date())
        let service = MockGitService()
        service.logToReturn = [
            commit(sha: "aaa1", subject: "just now", date: Date()),
            commit(sha: "bbb2", subject: "also today", date: startOfToday.addingTimeInterval(60)),
            commit(sha: "ccc3", subject: "long ago",
                   date: calendar.date(byAdding: .day, value: -90, to: startOfToday)!),
        ]
        let viewModel = makeViewModel(service)
        await viewModel.reload()

        let groups = viewModel.groupedCommits
        XCTAssertEqual(groups.first?.group, .today)
        XCTAssertEqual(groups.first?.commits.map(\.sha), ["aaa1", "bbb2"])
        XCTAssertEqual(groups.last?.commits.map(\.sha), ["ccc3"])
        if case .month = groups.last?.group {} else {
            XCTFail("a 90-day-old commit belongs in a month bucket")
        }
    }

    func testGroupingFollowsTheActiveFilter() async {
        let service = MockGitService()
        service.logToReturn = [
            commit(sha: "aaa1", subject: "keep me", hoursAgo: 1),
            commit(sha: "bbb2", subject: "hide me", hoursAgo: 2),
        ]
        let viewModel = makeViewModel(service)
        await viewModel.reload()

        viewModel.searchQuery = "keep"

        XCTAssertEqual(viewModel.groupedCommits.flatMap(\.commits).map(\.sha), ["aaa1"])
    }

    // MARK: - Decoration helpers

    func testUnpushedAndTipAreReported() async {
        let service = MockGitService()
        service.logToReturn = [commit(sha: "aaa1"), commit(sha: "bbb2")]
        service.unpushedSHAsToReturn = ["aaa1"]
        let viewModel = makeViewModel(service)
        await viewModel.reload()

        let tip = viewModel.commits[0]
        let older = viewModel.commits[1]
        XCTAssertTrue(viewModel.isTip(tip))
        XCTAssertFalse(viewModel.isTip(older))
        XCTAssertTrue(viewModel.isUnpushed(tip))
        XCTAssertFalse(viewModel.isUnpushed(older))
    }

    func testWebURLIsNilWithoutARemote() async {
        let service = MockGitService()
        service.logToReturn = [commit(sha: "abc1234")]
        let viewModel = makeViewModel(service)
        await viewModel.reload()

        XCTAssertNil(viewModel.webURL(for: viewModel.commits[0]))

        service.remoteURLToReturn = "git@github.com:Niclassslua/Flotilla.git"
        await viewModel.reload()

        XCTAssertEqual(
            viewModel.webURL(for: viewModel.commits[0])?.absoluteString,
            "https://github.com/Niclassslua/Flotilla/commit/abc1234"
        )
    }

    // MARK: - Agent attribution

    private func session(
        title: String,
        agent: AgentKind = .claudeCode,
        branch: String?
    ) -> Session {
        var session = Session(
            title: title,
            goal: "goal",
            agent: agent,
            projectID: nil,
            workingDirectory: repoPath
        )
        if let branch {
            session.worktree = WorktreeInfo(
                branchName: branch,
                worktreePath: repoPath.appendingPathComponent(branch),
                baseCheckoutPath: repoPath
            )
        }
        return session
    }

    private func serviceWithMainWorktree(_ base: String = "main") -> MockGitService {
        let service = MockGitService()
        service.worktreesToReturn = [
            GitWorktree(branch: base, path: repoPath, isMainWorktree: true)
        ]
        return service
    }

    func testCommitsOnASessionBranchAreAttributedToThatSession() async {
        let service = serviceWithMainWorktree()
        service.logToReturn = [commit(sha: "aaa1"), commit(sha: "bbb2"), commit(sha: "ccc3")]
        service.commitsOnBranchToReturn = ["feat/x": ["aaa1", "bbb2"]]
        let viewModel = makeViewModel(service)
        viewModel.sessions = [session(title: "Remove dead code", agent: .codexCLI, branch: "feat/x")]

        await viewModel.reload()

        let attributed = viewModel.attribution(for: viewModel.commits[0])
        XCTAssertEqual(attributed?.sessionTitle, "Remove dead code")
        XCTAssertEqual(attributed?.agent, .codexCLI)
        XCTAssertEqual(attributed?.branchName, "feat/x")
        XCTAssertNotNil(viewModel.attribution(for: viewModel.commits[1]))
        XCTAssertNil(viewModel.attribution(for: viewModel.commits[2]), "a commit off the branch stays unattributed")
    }

    func testSessionsWithoutAWorktreeAreNotQueried() async {
        let service = serviceWithMainWorktree()
        service.logToReturn = [commit(sha: "aaa1")]
        let viewModel = makeViewModel(service)
        viewModel.sessions = [session(title: "No worktree", branch: nil)]

        await viewModel.reload()

        XCTAssertTrue(service.commitsOnBranchCalls.isEmpty)
        XCTAssertTrue(viewModel.attributions.isEmpty)
    }

    /// A session working directly in the main checkout has no branch of its
    /// own, so nothing can be attributed to it.
    func testSessionOnTheBaseBranchIsNotQueried() async {
        let service = serviceWithMainWorktree("main")
        service.logToReturn = [commit(sha: "aaa1")]
        let viewModel = makeViewModel(service)
        viewModel.sessions = [session(title: "On main", branch: "main")]

        await viewModel.reload()

        XCTAssertTrue(service.commitsOnBranchCalls.isEmpty)
    }

    func testAttributionIsEmptyWithoutAMainWorktreeToCompareAgainst() async {
        let service = MockGitService()
        service.worktreesToReturn = []
        service.logToReturn = [commit(sha: "aaa1")]
        service.commitsOnBranchToReturn = ["feat/x": ["aaa1"]]
        let viewModel = makeViewModel(service)
        viewModel.sessions = [session(title: "Session", branch: "feat/x")]

        await viewModel.reload()

        XCTAssertTrue(viewModel.attributions.isEmpty, "no base means no reachability comparison")
    }

    // MARK: - Unseen commits

    /// Each test gets its own repo path so the persisted marker can't leak
    /// between them.
    private func isolatedViewModel(_ service: MockGitService) -> ProjectHistoryViewModel {
        ProjectHistoryViewModel(
            repoPath: URL(fileURLWithPath: "/tmp/flotilla-history-\(UUID().uuidString)"),
            gitService: service
        )
    }

    func testFirstEverVisitMarksNothingAsNew() async {
        let service = MockGitService()
        service.logToReturn = [commit(sha: "aaa1"), commit(sha: "bbb2")]
        let viewModel = isolatedViewModel(service)

        await viewModel.reload()

        XCTAssertEqual(viewModel.newCommitCount, 0, "with no prior marker, nothing can be 'new'")
    }

    func testCommitsLandingAfterTheLastVisitAreMarkedNew() async {
        let service = MockGitService()
        service.logToReturn = [commit(sha: "bbb2")]
        let viewModel = isolatedViewModel(service)
        await viewModel.reload()
        viewModel.markAllAsSeen()

        // A second visit, with a newer commit on top.
        let returning = ProjectHistoryViewModel(repoPath: viewModel.repoPath, gitService: service)
        service.logToReturn = [commit(sha: "aaa1"), commit(sha: "bbb2")]
        await returning.reload()

        XCTAssertEqual(returning.newCommitCount, 1)
        XCTAssertTrue(returning.isNew(returning.commits[0]))
        XCTAssertFalse(returning.isNew(returning.commits[1]))
        XCTAssertEqual(returning.firstSeenSHA, "bbb2", "the separator sits above the newest seen commit")
    }

    func testRefreshingDoesNotClearTheBadgesMidVisit() async {
        let service = MockGitService()
        service.logToReturn = [commit(sha: "bbb2")]
        let viewModel = isolatedViewModel(service)
        await viewModel.reload()
        viewModel.markAllAsSeen()

        let returning = ProjectHistoryViewModel(repoPath: viewModel.repoPath, gitService: service)
        service.logToReturn = [commit(sha: "aaa1"), commit(sha: "bbb2")]
        await returning.reload()
        XCTAssertEqual(returning.newCommitCount, 1)

        await returning.reload()

        XCTAssertEqual(returning.newCommitCount, 1, "the marker is captured once per visit, not per load")
    }

    func testMarkAllAsSeenClearsTheBadges() async {
        let service = MockGitService()
        service.logToReturn = [commit(sha: "bbb2")]
        let viewModel = isolatedViewModel(service)
        await viewModel.reload()
        viewModel.markAllAsSeen()

        let returning = ProjectHistoryViewModel(repoPath: viewModel.repoPath, gitService: service)
        service.logToReturn = [commit(sha: "aaa1"), commit(sha: "bbb2")]
        await returning.reload()
        XCTAssertEqual(returning.newCommitCount, 1)

        returning.markAllAsSeen()

        XCTAssertEqual(returning.newCommitCount, 0)
        XCTAssertNil(returning.firstSeenSHA)
    }

    func testDisablingTheSettingSuppressesAllUnseenTracking() async {
        let service = MockGitService()
        service.logToReturn = [commit(sha: "bbb2")]
        let viewModel = isolatedViewModel(service)
        await viewModel.reload()
        viewModel.markAllAsSeen()

        let returning = ProjectHistoryViewModel(repoPath: viewModel.repoPath, gitService: service)
        returning.highlightUnseenCommits = false
        service.logToReturn = [commit(sha: "aaa1"), commit(sha: "bbb2")]
        await returning.reload()

        XCTAssertEqual(returning.newCommitCount, 0)
        XCTAssertNil(returning.firstSeenSHA)
    }

    func testTogglingTheSettingBackOnRestoresTheBadges() async {
        let service = MockGitService()
        service.logToReturn = [commit(sha: "bbb2")]
        let viewModel = isolatedViewModel(service)
        await viewModel.reload()
        viewModel.markAllAsSeen()

        let returning = ProjectHistoryViewModel(repoPath: viewModel.repoPath, gitService: service)
        service.logToReturn = [commit(sha: "aaa1"), commit(sha: "bbb2")]
        await returning.reload()
        returning.highlightUnseenCommits = false
        XCTAssertEqual(returning.newCommitCount, 0)

        returning.highlightUnseenCommits = true

        XCTAssertEqual(returning.newCommitCount, 1, "the marker survives the setting being toggled")
    }

    func testRefMenuOffersWorktreeBranches() async {
        let service = MockGitService()
        service.logToReturn = [commit(sha: "aaa1")]
        service.worktreesToReturn = [
            GitWorktree(branch: "main", path: URL(fileURLWithPath: "/tmp/main"), isMainWorktree: true),
            GitWorktree(branch: "feat/x", path: URL(fileURLWithPath: "/tmp/feat"), isMainWorktree: false),
            GitWorktree(branch: "(detached)", path: URL(fileURLWithPath: "/tmp/det"), isMainWorktree: false),
        ]
        let viewModel = makeViewModel(service)

        await viewModel.reload()

        XCTAssertEqual(viewModel.availableRefs, ["main", "feat/x"], "a detached worktree isn't a ref to browse")
    }
}

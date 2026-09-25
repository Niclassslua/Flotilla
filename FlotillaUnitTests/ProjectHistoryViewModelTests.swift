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

    // MARK: - Loading & paging

    func testReloadPagingAndLoadIfNeeded() async {
        let service = MockGitService()
        service.logToReturn = [commit(sha: "aaa1", subject: "newest"), commit(sha: "bbb2", subject: "older")]
        let viewModel = makeViewModel(service)

        await viewModel.reload()
        XCTAssertEqual(viewModel.commits.map(\.subject), ["newest", "older"])
        XCTAssertEqual(viewModel.selectedSHA, "aaa1", "the detail pane must never start empty")
        XCTAssertNil(viewModel.errorMessage)
        XCTAssertFalse(viewModel.hasMore, "a page shorter than the page size is the end of history")

        await viewModel.loadIfNeeded()
        let callsAfterFirst = service.logCalls.count
        await viewModel.loadIfNeeded()
        XCTAssertEqual(service.logCalls.count, callsAfterFirst)

        service.errorToThrow = GitServiceError.commandFailed(exitCode: 128, stderr: "not a git repository")
        await viewModel.reload()
        XCTAssertTrue(viewModel.commits.isEmpty)
        XCTAssertFalse(viewModel.hasMore)
        XCTAssertNotNil(viewModel.errorMessage)

        service.errorToThrow = nil
        viewModel.searchQuery = ""
        // Empty parents — a shared fake parent makes GitGraphLayout explode at page size.
        service.logToReturn = (0..<(ProjectHistoryViewModel.pageSize + 20)).map {
            commit(sha: String(format: "sha-%03d", $0), subject: "commit \($0)", parents: [])
        }
        await viewModel.reload()
        XCTAssertNil(viewModel.errorMessage)
        XCTAssertEqual(viewModel.commits.count, ProjectHistoryViewModel.pageSize)
        XCTAssertTrue(viewModel.hasMore)
        await viewModel.loadMore()
        XCTAssertEqual(viewModel.commits.count, ProjectHistoryViewModel.pageSize + 20)
        XCTAssertEqual(Set(viewModel.commits.map(\.sha)).count, viewModel.commits.count, "no duplicates")
        XCTAssertFalse(viewModel.hasMore)

        let callsBeforeSearch = service.logCalls.count
        viewModel.searchQuery = "anything"
        await viewModel.loadMore()
        XCTAssertEqual(service.logCalls.count, callsBeforeSearch, "paging a filtered list would be misleading")
    }

    // MARK: - Filtering & grouping

    func testFilterAndGrouping() async {
        let calendar = Calendar.current
        let startOfToday = calendar.startOfDay(for: Date())
        let service = MockGitService()
        service.logToReturn = [
            commit(sha: "abc1234", subject: "fix(git): pipe race", author: "Niclassslua", date: Date()),
            commit(sha: "def5678", subject: "docs: update readme", author: "Ada Lovelace", email: "ada@example.com",
                   date: startOfToday.addingTimeInterval(60)),
            commit(sha: "ccc3", subject: "chore", body: "Closes the flaky collector",
                   date: calendar.date(byAdding: .day, value: -90, to: startOfToday)!),
        ]
        let viewModel = makeViewModel(service)
        await viewModel.reload()

        viewModel.searchQuery = "race"
        XCTAssertEqual(viewModel.filteredCommits.map(\.sha), ["abc1234"])
        viewModel.searchQuery = "ada"
        XCTAssertEqual(viewModel.filteredCommits.map(\.sha), ["def5678"])
        viewModel.searchQuery = "abc12"
        XCTAssertEqual(viewModel.filteredCommits.map(\.sha), ["abc1234"])
        viewModel.searchQuery = "flaky"
        XCTAssertEqual(viewModel.filteredCommits.map(\.sha), ["ccc3"])
        viewModel.searchQuery = "  "
        XCTAssertEqual(viewModel.filteredCommits.count, 3, "a blank query is not a filter")
        XCTAssertFalse(viewModel.isSearching)

        let groups = viewModel.groupedCommits
        XCTAssertEqual(groups.first?.group, .today)
        XCTAssertEqual(groups.first?.commits.map(\.sha), ["abc1234", "def5678"])
        XCTAssertEqual(groups.last?.commits.map(\.sha), ["ccc3"])
        if case .month = groups.last?.group {} else {
            XCTFail("a 90-day-old commit belongs in a month bucket")
        }

        viewModel.searchQuery = "race"
        XCTAssertEqual(viewModel.groupedCommits.flatMap(\.commits).map(\.sha), ["abc1234"])
    }

    // MARK: - Decorations

    func testTipUnpushedWebURLAndRefMenu() async {
        let service = MockGitService()
        service.logToReturn = [commit(sha: "abc1234"), commit(sha: "bbb2")]
        service.unpushedSHAsToReturn = ["abc1234"]
        service.worktreesToReturn = [
            GitWorktree(branch: "main", path: URL(fileURLWithPath: "/tmp/main"), isMainWorktree: true),
            GitWorktree(branch: "feat/x", path: URL(fileURLWithPath: "/tmp/feat"), isMainWorktree: false),
            GitWorktree(branch: "(detached)", path: URL(fileURLWithPath: "/tmp/det"), isMainWorktree: false),
        ]
        let viewModel = makeViewModel(service)
        await viewModel.reload()

        let tip = viewModel.commits[0]
        let older = viewModel.commits[1]
        XCTAssertTrue(viewModel.isTip(tip))
        XCTAssertFalse(viewModel.isTip(older))
        XCTAssertTrue(viewModel.isUnpushed(tip))
        XCTAssertFalse(viewModel.isUnpushed(older))
        XCTAssertNil(viewModel.webURL(for: tip))
        XCTAssertEqual(viewModel.availableRefs, ["main", "feat/x"], "a detached worktree isn't a ref to browse")

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

    func testAttributionQueriesSessionBranchesOnly() async {
        let service = serviceWithMainWorktree()
        service.logToReturn = [commit(sha: "aaa1"), commit(sha: "bbb2"), commit(sha: "ccc3")]
        service.commitsOnBranchToReturn = ["feat/x": ["aaa1", "bbb2"]]
        let viewModel = makeViewModel(service)
        viewModel.sessions = [session(title: "Remove dead code", agent: .codexCLI, branch: "feat/x")]
        await viewModel.reload()

        let attributed = viewModel.attribution(for: viewModel.commits[0])
        XCTAssertEqual(attributed?.sessionTitle, "Remove dead code")
        XCTAssertEqual(attributed?.prompt, "goal")
        XCTAssertEqual(attributed?.agent, .codexCLI)
        XCTAssertEqual(attributed?.branchName, "feat/x")
        XCTAssertNotNil(viewModel.attribution(for: viewModel.commits[1]))
        XCTAssertNil(viewModel.attribution(for: viewModel.commits[2]), "a commit off the branch stays unattributed")

        let noWorktree = serviceWithMainWorktree()
        noWorktree.logToReturn = [commit(sha: "aaa1")]
        let noWorktreeVM = makeViewModel(noWorktree)
        noWorktreeVM.sessions = [session(title: "No worktree", branch: nil)]
        await noWorktreeVM.reload()
        XCTAssertTrue(noWorktree.commitsOnBranchCalls.isEmpty)
        XCTAssertTrue(noWorktreeVM.attributions.isEmpty)

        let onMain = serviceWithMainWorktree("main")
        onMain.logToReturn = [commit(sha: "aaa1")]
        let onMainVM = makeViewModel(onMain)
        onMainVM.sessions = [session(title: "On main", branch: "main")]
        await onMainVM.reload()
        XCTAssertTrue(onMain.commitsOnBranchCalls.isEmpty)

        let noBase = MockGitService()
        noBase.worktreesToReturn = []
        noBase.logToReturn = [commit(sha: "aaa1")]
        noBase.commitsOnBranchToReturn = ["feat/x": ["aaa1"]]
        let emptyBase = makeViewModel(noBase)
        emptyBase.sessions = [session(title: "Session", branch: "feat/x")]
        await emptyBase.reload()
        XCTAssertTrue(emptyBase.attributions.isEmpty, "no base means no reachability comparison")
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

    func testUnseenCommitBadgesAndSetting() async {
        let service = MockGitService()
        service.logToReturn = [commit(sha: "aaa1"), commit(sha: "bbb2")]
        let firstVisit = isolatedViewModel(service)
        await firstVisit.reload()
        XCTAssertEqual(firstVisit.newCommitCount, 0, "with no prior marker, nothing can be 'new'")

        service.logToReturn = [commit(sha: "bbb2")]
        let seed = isolatedViewModel(service)
        await seed.reload()
        seed.markAllAsSeen()

        let returning = ProjectHistoryViewModel(repoPath: seed.repoPath, gitService: service)
        service.logToReturn = [commit(sha: "aaa1"), commit(sha: "bbb2")]
        await returning.reload()
        XCTAssertEqual(returning.newCommitCount, 1)
        XCTAssertTrue(returning.isNew(returning.commits[0]))
        XCTAssertFalse(returning.isNew(returning.commits[1]))
        XCTAssertEqual(returning.firstSeenSHA, "bbb2", "the separator sits above the newest seen commit")

        await returning.reload()
        XCTAssertEqual(returning.newCommitCount, 1, "the marker is captured once per visit, not per load")

        returning.markAllAsSeen()
        XCTAssertEqual(returning.newCommitCount, 0)
        XCTAssertNil(returning.firstSeenSHA)

        service.logToReturn = [commit(sha: "ccc3"), commit(sha: "aaa1"), commit(sha: "bbb2")]
        await returning.reload()
        XCTAssertEqual(returning.newCommitCount, 1)

        returning.highlightUnseenCommits = false
        XCTAssertEqual(returning.newCommitCount, 0)
        XCTAssertNil(returning.firstSeenSHA)

        returning.highlightUnseenCommits = true
        XCTAssertEqual(returning.newCommitCount, 1, "the marker survives the setting being toggled")
    }
}

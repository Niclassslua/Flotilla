import XCTest
import SessionKit
import GitKit
import PersistenceKit
import ProcessKit
import SettingsKit
@testable import Flotilla

/// Starting a session from a GitHub issue: what `gh` returns, what the draft
/// does with it, and what the created session carries.
final class GhIssueJSONTests: XCTestCase {
    func testListAndSingleIssuePayloadsDecode() throws {
        let list = #"""
        [
          {"number": 12, "title": "Crash on launch", "url": "https://github.com/acme/app/issues/12",
           "labels": [{"name": "bug", "color": "d73a4a"}, {"name": "p1"}], "updatedAt": "2026-10-01T10:00:00Z"},
          {"number": 9, "title": "Dark mode", "url": "https://github.com/acme/app/issues/9", "labels": []}
        ]
        """#
        let issues = try GhJSON.issues(from: Data(list.utf8))
        XCTAssertEqual(issues.map(\.number), [12, 9])
        XCTAssertEqual(issues.first?.labels, ["bug", "p1"])
        XCTAssertEqual(issues.first?.labelColors, ["bug": "d73a4a"])
        XCTAssertNotNil(issues.first?.updatedAt)
        XCTAssertEqual(issues.first?.body, "", "the list omits bodies")

        let single = #"{"number": 12, "title": "Crash on launch", "url": "https://github.com/acme/app/issues/12", "labels": [], "body": "Steps:\n1. Open"}"#
        XCTAssertEqual(try GhJSON.issues(from: Data(single.utf8)).first?.body, "Steps:\n1. Open")
    }

    /// The branch must still name the issue after the slug is truncated.
    func testIssueBranchKeepsTheNumberThroughTruncation() {
        let link = IssueLink(number: 1234, title: "A very long issue title that goes on well past the slug limit", url: URL(string: "https://x/1234")!)
        let branch = link.branchName(uuid: UUID(uuidString: "ABCDEF12-0000-0000-0000-000000000000")!)

        XCTAssertTrue(branch.hasPrefix("flotilla/issue-1234-a-very-long"), branch)
        XCTAssertTrue(branch.hasSuffix("-abcdef12"))
        XCTAssertEqual(link.sessionTitle, "#1234 A very long issue title that goes on well past the slug limit")
    }
}

@MainActor
final class IssueSessionTests: XCTestCase {
    private let issue = GhIssue(
        number: 42,
        title: "Fix login crash",
        url: URL(string: "https://github.com/acme/app/issues/42")!,
        body: "Users on Safari crash after SSO."
    )

    private func makeStore(settings: AppSettings = AppSettings(), git: MockGitService = MockGitService(), repository: GRDBSessionRepository? = nil) throws -> AppStore {
        AppStore(
            repository: try repository ?? GRDBSessionRepository(),
            gitService: git,
            ghService: MockGhService(),
            processManager: SessionProcessManager(
                locator: AppLayerExecutableLocator(executable: URL(fileURLWithPath: "/usr/bin/env")),
                processFactory: RecordingProcessFactory(),
                settingsProvider: { settings },
                tmuxServerProbe: AppLayerTmuxServerProbe(usable: false)
            ),
            worktreeBaseDirectoryProvider: { URL(fileURLWithPath: "/tmp/worktrees") },
            settingsProvider: { settings }
        )
    }

    private func makeDraft(store: AppStore, project: Project) -> SessionDraft {
        SessionDraft(
            store: store,
            initialProject: project,
            initialGoal: "my own notes",
            createWorktreeByDefault: true,
            fetchBeforeCreatingWorktree: false,
            defaultAgent: .claudeCode,
            openCodeSubscription: .none
        )
    }

    func testApplyingAnIssueFillsTheGoalAndUnlinkingRestoresIt() throws {
        let store = try makeStore()
        let draft = makeDraft(store: store, project: Project(name: "app", rootPath: URL(fileURLWithPath: "/tmp/app")))

        draft.apply(issue: issue)
        XCTAssertEqual(draft.linkedIssue?.number, 42)
        XCTAssertTrue(draft.goal.hasPrefix("#42 Fix login crash\n\nUsers on Safari crash after SSO."))
        XCTAssertTrue(draft.goal.contains("Closes #42"), "the agent is told to link its PR to the issue")
        XCTAssertEqual(draft.preview.title, "#42 Fix login crash")
        XCTAssertEqual(draft.preview.displayBranch.map { $0.hasPrefix("issue-42-fix-login-crash") }, true)

        draft.clearIssue()
        XCTAssertNil(draft.linkedIssue)
        XCTAssertEqual(draft.goal, "my own notes", "unlinking gives back what the user had typed")
    }

    /// An issue belongs to one repository; switching project must not launch
    /// another codebase's session named after it.
    func testSwitchingProjectUnlinksTheIssue() throws {
        let store = try makeStore()
        let draft = makeDraft(store: store, project: Project(name: "app", rootPath: URL(fileURLWithPath: "/tmp/app")))
        draft.apply(issue: issue)

        draft.select(folder: URL(fileURLWithPath: "/tmp/other"))

        XCTAssertNil(draft.linkedIssue)
        XCTAssertEqual(draft.goal, "my own notes")
    }

    /// Whatever the naming setting, an issue session is titled and branched
    /// after the issue — Apple Intelligence or the agent would rename it into
    /// something that no longer says which issue it fixes.
    func testCreatedSessionIsNamedForTheIssueAndPersistsTheLink() async throws {
        var settings = AppSettings()
        settings.sessionDefaults.namingSource = .agentManaged
        let git = MockGitService()
        let repository = try GRDBSessionRepository()
        let store = try makeStore(settings: settings, git: git, repository: repository)
        let link = IssueLink(number: 42, title: "Fix login crash", url: issue.url)

        let createdID = await store.createSession(
            title: "ignored",
            goal: SessionDraft.goal(for: issue),
            agent: .claudeCode,
            projectFolder: URL(fileURLWithPath: "/tmp/app"),
            checkoutMode: .newWorktree,
            linkedIssue: link
        )
        let id = try XCTUnwrap(createdID)

        let session = try XCTUnwrap(store.sessions.first { $0.id == id })
        XCTAssertEqual(session.title, "#42 Fix login crash")
        XCTAssertEqual(git.createWorktreeCalls.first?.branch.hasPrefix("flotilla/issue-42-fix-login-crash-"), true)
        XCTAssertEqual(try repository.loadAll().sessions.first { $0.id == id }?.linkedIssue, link)
    }
}

@MainActor
final class ProjectIssuesViewModelTests: XCTestCase {
    private func issue(_ number: Int) -> GhIssue {
        GhIssue(number: number, title: "Issue \(number)", url: URL(string: "https://github.com/acme/app/issues/\(number)")!, body: "Body \(number)")
    }

    private func session(issue number: Int?, createdMinutesAgo: Double = 0) -> Session {
        Session(
            title: "s",
            goal: "",
            agent: .claudeCode,
            projectID: UUID(),
            workingDirectory: URL(fileURLWithPath: "/tmp"),
            linkedIssue: number.map { IssueLink(number: $0, title: "Issue \($0)", url: URL(string: "https://github.com/acme/app/issues/\($0)")!) },
            createdAt: Date().addingTimeInterval(-createdMinutesAgo * 60)
        )
    }

    /// The tab's point is telling claimed work from unclaimed: the filters
    /// must split the backlog exactly by whether a session links the issue.
    func testFiltersSplitIssuesByLinkedSessions() async {
        let gh = MockGhService()
        gh.issuesToReturn = [issue(1), issue(2), issue(3)]
        let viewModel = ProjectIssuesViewModel(ghService: gh, repository: URL(fileURLWithPath: "/tmp/app"))
        await viewModel.load()
        let sessions = [session(issue: 2), session(issue: nil)]

        XCTAssertEqual(viewModel.visibleIssues(sessions: sessions).map(\.number), [1, 2, 3])
        viewModel.filter = .unclaimed
        XCTAssertEqual(viewModel.visibleIssues(sessions: sessions).map(\.number), [1, 3])
        viewModel.filter = .claimed
        XCTAssertEqual(viewModel.visibleIssues(sessions: sessions).map(\.number), [2])
    }

    func testSessionsForAnIssueAreNewestFirstAndExact() {
        let older = session(issue: 4, createdMinutesAgo: 30)
        let newer = session(issue: 4, createdMinutesAgo: 1)
        let other = session(issue: 40)

        XCTAssertEqual(ProjectIssuesViewModel.sessions(for: 4, in: [older, other, newer]).map(\.id), [newer.id, older.id])
    }

    func testSearchIsPassedToGhAndBodiesLoadOnce() async {
        let gh = MockGhService()
        gh.issuesToReturn = [issue(7)]
        let viewModel = ProjectIssuesViewModel(ghService: gh, repository: URL(fileURLWithPath: "/tmp/app"))
        viewModel.query = "label:bug"
        await viewModel.load()
        XCTAssertEqual(gh.issueSearches, ["label:bug"])

        await viewModel.loadDetail(for: 7)
        gh.issueErrorToThrow = GitServiceError.ghCommandFailed(exitCode: 1, stderr: "offline")
        await viewModel.loadDetail(for: 7)
        XCTAssertEqual(viewModel.details[7]?.body, "Body 7", "a loaded body is kept, not refetched")
        XCTAssertNil(viewModel.detailError)
    }

    func testLoadFailureIsShownNotSwallowed() async {
        let gh = MockGhService()
        gh.issueErrorToThrow = GitServiceError.ghCommandFailed(exitCode: 4, stderr: "gh auth login required")
        let viewModel = ProjectIssuesViewModel(ghService: gh, repository: URL(fileURLWithPath: "/tmp/app"))
        await viewModel.load()

        XCTAssertEqual(viewModel.errorMessage, "gh auth login required")
        XCTAssertTrue(viewModel.hasLoaded)
    }
}

@MainActor
final class IssueFeedTests: XCTestCase {
    func testLoadsOnceAndSearchesLocally() async {
        let gh = MockGhService()
        gh.issuesToReturn = [
            GhIssue(number: 12, title: "Crash on launch", url: URL(string: "https://x/12")!, labels: ["bug"]),
            GhIssue(number: 120, title: "Dark mode", url: URL(string: "https://x/120")!, labels: ["ui"]),
        ]
        let feed = IssueFeed()
        await feed.load(ghService: gh, repository: URL(fileURLWithPath: "/tmp/app"))

        XCTAssertEqual(feed.issues(matching: "#12").map(\.number), [12, 120])
        XCTAssertEqual(feed.issues(matching: "crash").map(\.number), [12])
        XCTAssertEqual(feed.issues(matching: "UI").map(\.number), [120])
        XCTAssertEqual(gh.issueSearches, [""], "searching locally asks GitHub nothing")
    }
}

import XCTest
import SessionKit
import GitKit
@testable import Flotilla

final class ProjectOverviewTests: XCTestCase {

    @MainActor
    func testOverviewSelectionRestoresProjectAndTabAfterVisitingSessions() {
        let navigator = WorkspaceNavigator()
        let projectID = UUID()

        navigator.selection = .project(projectID)
        navigator.setProjectTab(.files, for: projectID)
        navigator.selection = .allSessions
        navigator.restoreHomeSelection()

        XCTAssertEqual(navigator.selection, .project(projectID))
        XCTAssertEqual(navigator.projectTab(for: projectID), .files)
    }

    @MainActor
    func testProjectBackMakesDashboardTheRestoredOverviewSelection() {
        let navigator = WorkspaceNavigator()

        navigator.selection = .project(UUID())
        navigator.showHomeDashboard()
        navigator.selection = .allSessions
        navigator.restoreHomeSelection()

        XCTAssertEqual(navigator.selection, .overview)
    }

    @MainActor
    func testFileBrowserModelIsRetainedForWorkspaceRoot() {
        let navigator = WorkspaceNavigator()
        let root = URL(fileURLWithPath: "/tmp/flotilla-navigation-files")

        let first = navigator.fileBrowserViewModel(for: root)
        let restored = navigator.fileBrowserViewModel(for: root.appendingPathComponent("..").appendingPathComponent("flotilla-navigation-files"))

        XCTAssertTrue(first === restored)
    }

    @MainActor
    func testGitCommitsSubTabIsRetainedAfterVisitingSessions() {
        let navigator = WorkspaceNavigator()
        let projectID = UUID()

        navigator.selection = .project(projectID)
        navigator.setProjectTab(.git, for: projectID)
        navigator.setProjectGitSubTab(.commits, for: projectID)
        navigator.selection = .allSessions
        navigator.restoreHomeSelection()

        XCTAssertEqual(navigator.selection, .project(projectID))
        XCTAssertEqual(navigator.projectTab(for: projectID), .git)
        XCTAssertEqual(navigator.projectGitSubTab(for: projectID), .commits)
    }

    @MainActor
    func testSessionsUsedThisWeekCountsOnlySessionsActiveOrCreatedWithinSevenDays() {
        let calendar = Calendar(identifier: .gregorian)
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let projectID = UUID()

        // Active 2 days ago, created 10 days ago -> used this week
        let activeRecently = Session(
            id: UUID(),
            title: "Active Recently",
            goal: "Goal",
            agent: .claudeCode,
            projectID: projectID,
            workingDirectory: URL(fileURLWithPath: "/tmp/s1"),
            createdAt: now.addingTimeInterval(-10 * 86400),
            lastActiveAt: now.addingTimeInterval(-2 * 86400)
        )

        // Created 3 days ago, active 3 days ago -> used this week
        let createdRecently = Session(
            id: UUID(),
            title: "Created Recently",
            goal: "Goal",
            agent: .claudeCode,
            projectID: projectID,
            workingDirectory: URL(fileURLWithPath: "/tmp/s2"),
            createdAt: now.addingTimeInterval(-3 * 86400),
            lastActiveAt: now.addingTimeInterval(-3 * 86400)
        )

        // Created 20 days ago, last active 8 days ago -> NOT used this week
        let staleSession = Session(
            id: UUID(),
            title: "Stale Session",
            goal: "Goal",
            agent: .claudeCode,
            projectID: projectID,
            workingDirectory: URL(fileURLWithPath: "/tmp/s3"),
            createdAt: now.addingTimeInterval(-20 * 86400),
            lastActiveAt: now.addingTimeInterval(-8 * 86400)
        )

        let sessions = [activeRecently, createdRecently, staleSession]

        let count = ProjectOverviewViewModel.sessionsUsedThisWeek(in: sessions, now: now, calendar: calendar)
        XCTAssertEqual(count, 2, "Should count only the 2 sessions active or created in the past 7 days, not the total 3 sessions")
    }

    @MainActor
    func testSessionsUsedThisWeekWithNoMatchingSessionsReturnsZero() {
        let calendar = Calendar(identifier: .gregorian)
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let oldSession = Session(
            id: UUID(),
            title: "Old Session",
            goal: "Goal",
            agent: .claudeCode,
            projectID: UUID(),
            workingDirectory: URL(fileURLWithPath: "/tmp/s-old"),
            createdAt: now.addingTimeInterval(-30 * 86400),
            lastActiveAt: now.addingTimeInterval(-14 * 86400)
        )

        XCTAssertEqual(ProjectOverviewViewModel.sessionsUsedThisWeek(in: [oldSession], now: now, calendar: calendar), 0)
        XCTAssertEqual(ProjectOverviewViewModel.sessionsUsedThisWeek(in: [], now: now, calendar: calendar), 0)
    }

    @MainActor
    func testWorktreesArePopulatedAndLoadingStateResolves() async {
        let mockGit = MockGitService()
        let root = URL(fileURLWithPath: "/tmp/project")
        let wt1 = GitWorktree(branch: "main", path: root, isMainWorktree: true)
        let wt2 = GitWorktree(branch: "feature-1", path: root.appendingPathComponent("wt-1"), isMainWorktree: false)
        let wt3 = GitWorktree(branch: "feature-2", path: root.appendingPathComponent("wt-2"), isMainWorktree: false)
        mockGit.worktreesToReturn = [wt1, wt2, wt3]

        let viewModel = ProjectOverviewViewModel(gitService: mockGit)
        await viewModel.load(root: root)

        XCTAssertFalse(viewModel.isLoadingWorktrees, "Loading worktrees flag should resolve to false")
        XCTAssertEqual(viewModel.worktrees.count, 3)
        XCTAssertEqual(viewModel.worktrees.map(\.branch), ["main", "feature-1", "feature-2"])
        XCTAssertEqual(viewModel.snapshots.count, 3)
    }

    func testWorktreeSnapshotStreamingYieldsAllPaths() async {
        let mockGit = MockGitService()
        let paths = [
            URL(fileURLWithPath: "/tmp/p1"),
            URL(fileURLWithPath: "/tmp/p2"),
            URL(fileURLWithPath: "/tmp/p3")
        ]
        mockGit.diffStatToReturn = GitDiffStat(additions: 5, deletions: 2)

        var streamed: [URL: WorktreeSnapshot] = [:]
        for await (path, snapshot) in WorktreeSnapshot.streamSnapshots(paths: paths, git: mockGit) {
            streamed[path.standardizedFileURL] = snapshot
        }

        XCTAssertEqual(streamed.count, 3)
        for path in paths {
            XCTAssertEqual(streamed[path.standardizedFileURL]?.diffStat.additions, 5)
            XCTAssertEqual(streamed[path.standardizedFileURL]?.diffStat.deletions, 2)
        }
    }

}


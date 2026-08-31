import XCTest
import SessionKit
@testable import Flotilla

final class ProjectOverviewTests: XCTestCase {

    // MARK: - Active Session Filtering

    func testActiveSessionFilteringSelectsWorkingAndWaitingForInput() {
        let working = fixtureSession(title: "Worker", status: .working)
        let waiting = fixtureSession(title: "Waiter", status: .waitingForInput)
        let idle = fixtureSession(title: "Idler", status: nil)
        let finished = fixtureSession(title: "Done", status: .readyForReview)
        let crashed = fixtureSession(title: "Crashed", status: .crashed)

        let all = [working, waiting, idle, finished, crashed]
        let active = all.filter { $0.status == .working || $0.status == .waitingForInput }

        XCTAssertEqual(active.count, 2)
        XCTAssertTrue(active.contains(where: { $0.title == "Worker" }))
        XCTAssertTrue(active.contains(where: { $0.title == "Waiter" }))
    }

    func testActiveSessionFilteringExcludesTerminalStates() {
        let finished = fixtureSession(title: "Finished", status: .readyForReview)
        let crashed = fixtureSession(title: "Crashed", status: .crashed)
        let idle = fixtureSession(title: "Idle", status: nil)

        let all = [finished, crashed, idle]
        let active = all.filter { $0.status == .working || $0.status == .waitingForInput }

        XCTAssertTrue(active.isEmpty, "Terminal and idle states should not appear in active sessions")
    }

    // MARK: - Recent Sessions (excludes active)

    func testRecentSessionsExcludesActiveSessions() {
        let working = fixtureSession(title: "Active", status: .working)
        let idle = fixtureSession(title: "Recent", status: nil)

        let all = [working, idle]
        let activeIDs = Set(all.filter { $0.status == .working || $0.status == .waitingForInput }.map(\.id))
        let recent = all.filter { !activeIDs.contains($0.id) }

        XCTAssertEqual(recent.count, 1)
        XCTAssertEqual(recent.first?.title, "Recent")
    }

    // MARK: - ProjectTab

    func testProjectTabAllCasesHasFiveEntries() {
        XCTAssertEqual(ProjectDetailView.ProjectTab.allCases.count, 5)
    }

    func testProjectTabTitlesAreCorrect() {
        let tabs = ProjectDetailView.ProjectTab.allCases
        XCTAssertEqual(tabs.map(\.title), ["Overview", "Git", "Files", "Skills", "Rules"])
    }

    func testProjectTabSystemImagesAreCorrect() {
        let tabs = ProjectDetailView.ProjectTab.allCases
        XCTAssertEqual(tabs.map(\.systemImage), [
            "square.grid.2x2",
            "arrow.triangle.branch",
            "folder",
            "sparkles",
            "doc.badge.gearshape"
        ])
    }

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

    // MARK: - Helpers

    private func fixtureSession(title: String, status: SessionStatus?) -> Session {
        Session(
            title: title,
            goal: "Test goal",
            agent: .claudeCode,
            projectID: nil,
            workingDirectory: URL(fileURLWithPath: "/tmp/test"),
            status: status
        )
    }
}

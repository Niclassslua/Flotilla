import XCTest
import SessionKit
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

}

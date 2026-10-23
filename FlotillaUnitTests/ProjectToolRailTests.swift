import XCTest
import SessionKit
@testable import Flotilla

@MainActor
final class ProjectToolRailTests: XCTestCase {

    private func session(project: UUID?) -> Session {
        Session(
            title: "Rail",
            goal: "Goal",
            agent: .claudeCode,
            projectID: project,
            workingDirectory: URL(fileURLWithPath: "/tmp/rail")
        )
    }

    func testRailProjectContextFromSelectionAndGroup() {
        let navigator = WorkspaceNavigator()
        let project = UUID()
        let other = UUID()
        let sessions = [session(project: project), session(project: nil)]

        navigator.selection = .overview
        XCTAssertNil(navigator.railProjectID(sessions: sessions))

        navigator.selection = .session(sessions[1].id)
        XCTAssertNil(navigator.railProjectID(sessions: sessions), "General sessions disable the rail")

        navigator.selection = .session(sessions[0].id)
        XCTAssertEqual(navigator.railProjectID(sessions: sessions), project)

        navigator.selection = .allSessions
        navigator.sessionGroup = .all
        XCTAssertNil(navigator.railProjectID(sessions: sessions))

        navigator.sessionGroup = .project(project)
        XCTAssertEqual(navigator.railProjectID(sessions: sessions), project)

        navigator.selection = .project(other)
        XCTAssertEqual(navigator.railProjectID(sessions: sessions), other)
        XCTAssertNil(navigator.activeRailTool)
    }

    func testOpenProjectToolRecordsHistoryAndHighlightsRail() {
        let navigator = WorkspaceNavigator()
        let project = UUID()
        let sessionID = UUID()
        navigator.selection = .session(sessionID)
        navigator.openProjectTool(.files, projectID: project)

        XCTAssertEqual(navigator.selection, .projectTool(project, .files))
        XCTAssertEqual(navigator.activeRailTool, .files)
        XCTAssertEqual(navigator.projectTab(for: project), .files)
        XCTAssertTrue(navigator.canGoBack)

        navigator.openProjectTool(.git, projectID: project)
        XCTAssertEqual(navigator.activeRailTool, .git)
        XCTAssertEqual(navigator.projectGitSubTab(for: project), .commits)

        navigator.setProjectGitSubTab(.changes, for: project)
        navigator.openProjectTool(.files, projectID: project)
        navigator.openProjectTool(.git, projectID: project)
        XCTAssertEqual(navigator.projectGitSubTab(for: project), .changes)

        navigator.goBack() // files
        XCTAssertEqual(navigator.selection, .projectTool(project, .files))
        navigator.goBack() // first git open
        XCTAssertEqual(navigator.selection, .projectTool(project, .git))
        navigator.goBack() // files (from session → files)
        XCTAssertEqual(navigator.selection, .projectTool(project, .files))
        navigator.goBack()
        XCTAssertEqual(navigator.selection, .session(sessionID))
    }

    func testOpenProjectToolLeavesActiveToolWhenReclicked() {
        let navigator = WorkspaceNavigator()
        let project = UUID()
        navigator.openProjectTool(.issues, projectID: project)
        let before = navigator.backStack.count
        navigator.openProjectTool(.issues, projectID: project)
        // Same destination — SidebarItem equality means didSet does not re-record.
        XCTAssertEqual(navigator.selection, .projectTool(project, .issues))
        XCTAssertEqual(navigator.backStack.count, before)
    }

    func testPruneRemovesStaleToolDestination() {
        let navigator = WorkspaceNavigator()
        let project = UUID()
        navigator.openProjectTool(.skills, projectID: project)
        navigator.pruneProjectDestinations(against: [])
        XCTAssertEqual(navigator.selection, .overview)
        XCTAssertNil(navigator.activeRailTool)
    }

    func testGitOpenDoesNotResetExistingBranchFilter() {
        let navigator = WorkspaceNavigator()
        let project = UUID()
        let scope = URL(fileURLWithPath: "/tmp/worktree-a")
        navigator.setProjectGitScope(scope, for: project)
        navigator.openProjectTool(.git, projectID: project)
        XCTAssertEqual(navigator.projectGitScope(for: project), scope)
    }
}

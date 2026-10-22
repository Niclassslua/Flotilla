import XCTest
import SessionKit
@testable import Flotilla

/// Back/forward is new in U2 — the app previously had no way to return to a
/// previous location — and its edge cases (branch truncation, self-recording,
/// bounded depth) are exactly the kind that regress silently.
@MainActor
final class WorkspaceNavigatorHistoryTests: XCTestCase {

    private func makeNavigator() -> WorkspaceNavigator {
        WorkspaceNavigator()
    }

    func testBackForwardAndBranchAbandonment() {
        let navigator = makeNavigator()
        XCTAssertFalse(navigator.canGoBack)
        XCTAssertFalse(navigator.canGoForward)

        let project = UUID()
        let session = UUID()
        navigator.selection = .allSessions
        navigator.selection = .project(project)
        XCTAssertTrue(navigator.canGoBack)
        navigator.goBack()
        XCTAssertEqual(navigator.selection, .allSessions)
        navigator.goBack()
        XCTAssertEqual(navigator.selection, .overview)
        XCTAssertFalse(navigator.canGoBack)

        navigator.selection = .allSessions
        navigator.selection = .smartList(.needsYou)
        navigator.selection = .session(session)
        navigator.goBack()
        XCTAssertEqual(navigator.selection, .smartList(.needsYou))
        navigator.goForward()
        XCTAssertEqual(navigator.selection, .session(session))

        navigator.goBack()
        XCTAssertTrue(navigator.canGoForward)
        navigator.selection = .smartList(.working)
        XCTAssertFalse(navigator.canGoForward, "a fresh navigation must drop the forward branch")
    }

    func testReselectAndHistoryMovesDoNotCorruptStacks() {
        let navigator = makeNavigator()
        navigator.selection = .allSessions
        navigator.selection = .allSessions
        navigator.selection = .allSessions
        navigator.goBack()
        XCTAssertEqual(navigator.selection, .overview)
        XCTAssertFalse(navigator.canGoBack)

        navigator.selection = .allSessions
        navigator.selection = .smartList(.ready)
        navigator.goBack()
        navigator.goBack()
        XCTAssertEqual(navigator.selection, .overview)
        XCTAssertFalse(navigator.canGoBack)
        navigator.goForward()
        navigator.goForward()
        XCTAssertEqual(navigator.selection, .smartList(.ready))
        XCTAssertFalse(navigator.canGoForward)

        for _ in 0..<200 {
            navigator.selection = .project(UUID())
        }
        XCTAssertLessThanOrEqual(navigator.backStack.count, 50)
    }

    func testShowHomeDashboardBringsUserToOverviewFromAnyScope() {
        let navigator = makeNavigator()
        let session = UUID()
        let project = UUID()

        for selection: SidebarItem in [
            .session(session), .project(project), .projectTool(project, .git),
            .allSessions, .smartList(.working)
        ] {
            navigator.selection = selection
            navigator.showHomeDashboard()
            XCTAssertEqual(navigator.selection, .overview)
        }
    }

    func testNilSelectedSessionIDLeavesDeletedSession() {
        let navigator = makeNavigator()
        let session = UUID()
        navigator.selection = .session(session)
        XCTAssertEqual(navigator.selectedSessionID, session)

        navigator.selectedSessionID = nil

        XCTAssertEqual(navigator.selection, .allSessions)
        XCTAssertNil(navigator.selectedSessionID)
        XCTAssertNil(navigator.focusedSessionID)
    }

    func testNilSelectedProjectIDLeavesDeletedProject() {
        let navigator = makeNavigator()
        let project = UUID()
        navigator.selection = .project(project)

        navigator.selectedProjectID = nil

        XCTAssertEqual(navigator.selection, .overview)
        XCTAssertNil(navigator.selectedProjectID)
    }

    func testCollectionKeepsFocusedSessionID() {
        let navigator = makeNavigator()
        let session = UUID()
        navigator.selection = .session(session)
        navigator.selection = .allSessions

        XCTAssertEqual(navigator.selection, .allSessions)
        XCTAssertEqual(navigator.focusedSessionID, session)
        XCTAssertEqual(navigator.selectedSessionID, session)

        navigator.selection = .smartList(.needsYou)
        XCTAssertEqual(navigator.selectedSessionID, session)

        navigator.selectedSessionID = UUID()
        XCTAssertEqual(navigator.selection, .smartList(.needsYou), "Focus target must not yank selection off the collection")
        XCTAssertEqual(navigator.selectedSessionID, navigator.focusedSessionID)
    }

    func testHistorySkipsDeletedSessionsAndProjects() {
        let navigator = makeNavigator()
        let aliveSession = UUID()
        let deadSession = UUID()
        let aliveProject = UUID()
        let deadProject = UUID()

        navigator.selection = .session(aliveSession)
        navigator.selection = .session(deadSession)
        navigator.selection = .project(deadProject)
        navigator.selection = .project(aliveProject)
        navigator.selection = .allSessions

        navigator.pruneNavigation(sessions: [aliveSession], projects: [aliveProject])

        XCTAssertFalse(navigator.backStack.contains(.session(deadSession)))
        XCTAssertFalse(navigator.backStack.contains(.project(deadProject)))
        XCTAssertTrue(navigator.backStack.contains(.session(aliveSession)))
        XCTAssertTrue(navigator.backStack.contains(.project(aliveProject)))

        navigator.goBack()
        XCTAssertEqual(navigator.selection, .project(aliveProject))
        navigator.goBack()
        XCTAssertEqual(navigator.selection, .session(aliveSession))
        XCTAssertFalse(navigator.backStack.contains(where: {
            if case .session(let id) = $0 { return id == deadSession }
            if case .project(let id) = $0 { return id == deadProject }
            return false
        }))
    }

    func testPruneNavigationLeavesTombstoneSelection() {
        let navigator = makeNavigator()
        let deadSession = UUID()
        let deadProject = UUID()

        navigator.selection = .session(deadSession)
        navigator.pruneNavigation(sessions: [], projects: [])
        XCTAssertEqual(navigator.selection, .allSessions)

        navigator.selection = .project(deadProject)
        navigator.pruneNavigation(sessions: [], projects: [])
        XCTAssertEqual(navigator.selection, .overview)
    }
}

/// One scope drives every presentation, so switching Grid/Board/Focus changes
/// how the fleet is shown and never which sessions are in it.
@MainActor
final class SessionScopeTests: XCTestCase {

    private func session(_ status: SessionStatus?, project: UUID? = nil) -> Session {
        Session(
            title: "Test",
            goal: "Do the thing",
            agent: .claudeCode,
            projectID: project,
            workingDirectory: URL(fileURLWithPath: "/tmp"),
            status: status
        )
    }

    func testSmartListsAndNavigatorScope() {
        let waiting = session(.waitingForInput)
        let crashed = session(.crashed)
        let working = session(.working)
        let ready = session(.readyForReview)
        let sessions = [waiting, crashed, working, ready]
        XCTAssertEqual(Set(FleetSmartList.needsYou.filter(sessions).map(\.id)), Set([waiting.id, crashed.id]))
        XCTAssertEqual(FleetSmartList.working.filter(sessions).map(\.id), [working.id])
        XCTAssertEqual(FleetSmartList.ready.filter(sessions).map(\.id), [ready.id])

        let navigator = WorkspaceNavigator()
        let project = UUID()
        navigator.selection = .smartList(.ready)
        XCTAssertEqual(navigator.sessionScope, SessionScope(group: .all, smartList: .ready))
        navigator.selection = .project(project)
        XCTAssertEqual(navigator.sessionScope, SessionScope(group: .project(project), smartList: nil))
        navigator.selection = .allSessions
        XCTAssertTrue(navigator.sessionScope.isEverything)
    }
}

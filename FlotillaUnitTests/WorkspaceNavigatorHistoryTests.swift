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
            .session(session), .project(project), .allSessions, .smartList(.working)
        ] {
            navigator.selection = selection
            navigator.showHomeDashboard()
            XCTAssertEqual(navigator.selection, .overview)
        }
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

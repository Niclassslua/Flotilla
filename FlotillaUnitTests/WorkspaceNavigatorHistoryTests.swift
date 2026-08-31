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

    func testStartsWithNoHistory() {
        let navigator = makeNavigator()
        XCTAssertFalse(navigator.canGoBack)
        XCTAssertFalse(navigator.canGoForward)
    }

    func testBackReturnsToThePreviousSelection() {
        let navigator = makeNavigator()
        let project = UUID()

        navigator.selection = .allSessions
        navigator.selection = .project(project)

        XCTAssertTrue(navigator.canGoBack)
        navigator.goBack()
        XCTAssertEqual(navigator.selection, .allSessions)
        navigator.goBack()
        XCTAssertEqual(navigator.selection, .overview)
        XCTAssertFalse(navigator.canGoBack)
    }

    /// The acceptance test for this unit: three navigations, then back returns
    /// you where you were rather than to some root.
    func testBackAcrossThreeNavigations() {
        let navigator = makeNavigator()
        let session = UUID()

        navigator.selection = .allSessions
        navigator.selection = .smartList(.needsYou)
        navigator.selection = .session(session)

        navigator.goBack()
        XCTAssertEqual(navigator.selection, .smartList(.needsYou))
        navigator.goForward()
        XCTAssertEqual(navigator.selection, .session(session))
    }

    func testForwardIsAbandonedByANewNavigation() {
        let navigator = makeNavigator()
        navigator.selection = .allSessions
        navigator.goBack()
        XCTAssertTrue(navigator.canGoForward)

        navigator.selection = .smartList(.working)
        XCTAssertFalse(navigator.canGoForward, "a fresh navigation must drop the forward branch")
    }

    /// Re-selecting what is already open is not a navigation. Without this the
    /// back stack fills with duplicates and Back appears to do nothing.
    func testReselectingTheSameItemRecordsNothing() {
        let navigator = makeNavigator()
        navigator.selection = .allSessions
        navigator.selection = .allSessions
        navigator.selection = .allSessions

        navigator.goBack()
        XCTAssertEqual(navigator.selection, .overview)
        XCTAssertFalse(navigator.canGoBack)
    }

    /// Back and Forward move `selection` themselves; if that move were
    /// recorded, each would push onto the stack it is popping and the two
    /// would never terminate.
    func testHistoryNavigationDoesNotRecordItself() {
        let navigator = makeNavigator()
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
    }

    func testBackStackIsBounded() {
        let navigator = makeNavigator()
        for _ in 0..<200 {
            navigator.selection = .project(UUID())
        }
        XCTAssertLessThanOrEqual(navigator.backStack.count, 50)
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

    func testEverythingPassesEverySessionThrough() {
        let sessions = [session(.working), session(.crashed), session(nil)]
        XCTAssertEqual(SessionScope.everything.apply(to: sessions).count, 3)
        XCTAssertTrue(SessionScope.everything.isEverything)
    }

    /// Needs You spans two statuses on purpose: a crashed agent and a blocked
    /// one both need a human. The distinction survives in each row's own
    /// status word.
    func testNeedsYouCoversWaitingAndCrashed() {
        let sessions = [session(.waitingForInput), session(.crashed), session(.working), session(.readyForReview)]
        let matched = FleetSmartList.needsYou.filter(sessions)
        XCTAssertEqual(matched.count, 2)
        XCTAssertEqual(FleetSmartList.working.filter(sessions).count, 1)
        XCTAssertEqual(FleetSmartList.ready.filter(sessions).count, 1)
    }

    func testProjectAndSmartListNarrowTogether() {
        let project = UUID()
        let sessions = [
            session(.waitingForInput, project: project),
            session(.working, project: project),
            session(.waitingForInput, project: UUID())
        ]
        let scope = SessionScope(group: .project(project), smartList: .needsYou)
        XCTAssertEqual(scope.apply(to: sessions).count, 1)
        XCTAssertFalse(scope.isEverything)
    }

    func testNavigatorDerivesScopeFromSelection() {
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

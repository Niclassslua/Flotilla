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
        let scope = SessionScope(projectID: project, smartList: .needsYou)
        XCTAssertEqual(scope.apply(to: sessions).count, 1)
        XCTAssertFalse(scope.isEverything)
    }

    func testNavigatorDerivesScopeFromSelection() {
        let navigator = WorkspaceNavigator()
        let project = UUID()

        navigator.selection = .smartList(.ready)
        XCTAssertEqual(navigator.sessionScope, SessionScope(projectID: nil, smartList: .ready))

        navigator.selection = .project(project)
        XCTAssertEqual(navigator.sessionScope, SessionScope(projectID: project, smartList: nil))

        navigator.selection = .allSessions
        XCTAssertTrue(navigator.sessionScope.isEverything)
    }
}

/// The window subtitle is the only place a focused session states its branch,
/// agent and model — the terminal fills everything else — so its edge cases
/// are worth pinning.
@MainActor
final class SessionIdentityLineTests: XCTestCase {

    private func session(
        model: String? = nil,
        worktree: WorktreeInfo? = nil,
        workingDirectory: String = "/tmp/checkout"
    ) -> Session {
        Session(
            title: "Fix login",
            goal: "g",
            agent: .claudeCode,
            projectID: nil,
            workingDirectory: URL(fileURLWithPath: workingDirectory),
            worktree: worktree
        )
        .with(model: model)
    }

    private func project(_ name: String) -> Project {
        Project(name: name, rootPath: URL(fileURLWithPath: "/tmp/repo"))
    }

    func testCarriesProjectAgentAndBranch() {
        let worktree = WorktreeInfo(
            branchName: "flotilla/fix-login",
            worktreePath: URL(fileURLWithPath: "/tmp/wt/fix-login"),
            baseCheckoutPath: URL(fileURLWithPath: "/tmp/repo")
        )
        let line = DetailColumn.identity(of: session(worktree: worktree), project: project("Flotilla"))
        XCTAssertEqual(line, "Flotilla · Claude Code · flotilla/fix-login")
    }

    func testIncludesModelWhenSet() {
        let line = DetailColumn.identity(of: session(model: "opus"), project: project("Flotilla"))
        XCTAssertTrue(line.contains("opus"), line)
    }

    /// Regression: this used to fall back to repeating the agent name, giving
    /// "Flotilla · Claude Code · Claude Code".
    func testWithoutAWorktreeNamesTheDirectoryNotTheAgentTwice() {
        let line = DetailColumn.identity(of: session(), project: project("Flotilla"))
        XCTAssertEqual(line, "Flotilla · Claude Code · checkout")
        XCTAssertFalse(line.hasSuffix("Claude Code"), "the agent should not appear twice")
    }

    /// Regression: an unassigned session produced an empty subtitle, so the
    /// sessions with the fewest affordances also lost their identity entirely.
    func testUnassignedSessionStillStatesItself() {
        let line = DetailColumn.identity(of: session(), project: nil)
        XCTAssertFalse(line.isEmpty)
        XCTAssertTrue(line.hasPrefix("Unassigned"), line)
    }
}

private extension Session {
    func with(model: String?) -> Session {
        var copy = self
        copy.model = model
        return copy
    }
}

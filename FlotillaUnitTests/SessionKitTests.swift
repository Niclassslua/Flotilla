import XCTest
import SessionKit

final class SessionStatusMachineTests: XCTestCase {
    private let machine = SessionStatusMachine()

    private func makeSession(status: SessionStatus?) -> Session {
        Session(
            title: "Test",
            goal: "Do the thing",
            agent: .claudeCode,
            projectID: nil,
            workingDirectory: URL(fileURLWithPath: "/tmp"),
            status: status
        )
    }

    // Every legal transition, exhaustively. `working`, `waitingForInput` and
    // `readyForReview` interchange freely; `nil` (no status yet) accepts any
    // first value; `crashed` reopens only via `working`.
    func testLegalTransitions() {
        let free: [SessionStatus] = [.working, .waitingForInput, .readyForReview]
        for from in free {
            for to in free where from != to {
                XCTAssertTrue(machine.canTransition(from: from, to: to), "\(from) -> \(to) should be legal")
            }
            XCTAssertTrue(machine.canTransition(from: from, to: .crashed), "\(from) -> crashed should be legal")
        }
        for to in SessionStatus.allCases {
            XCTAssertTrue(machine.canTransition(from: nil, to: to), "nil -> \(to) should be legal")
        }
        XCTAssertTrue(machine.canTransition(from: .crashed, to: .working))
    }

    /// `crashed` is re-enterable only through `.working`, the status an
    /// explicit restart moves a session to. Nothing else may reopen it — in
    /// particular no output-derived status, which is what keeps a stray
    /// repaint from resurrecting a session that has stopped.
    func testCrashedOnlyReopensViaExplicitRestart() {
        for target in SessionStatus.allCases {
            XCTAssertEqual(
                machine.canTransition(from: .crashed, to: target),
                target == .working,
                "crashed may transition only to working"
            )
        }
    }

    func testSelfTransitionsAreIllegal() {
        for status in SessionStatus.allCases {
            XCTAssertFalse(machine.canTransition(from: status, to: status), "\(status) -> \(status) should be illegal")
        }
    }

    func testFirstStatusFromNilIsAlwaysLegal() {
        let session = makeSession(status: nil)
        let result = machine.transition(session, to: .readyForReview)
        XCTAssertEqual(result.status, .readyForReview)
    }

    func testIllegalTransitionLeavesSessionUnchanged() {
        let session = makeSession(status: .crashed)
        // A crashed session cannot drift back to readyForReview on its own.
        let result = machine.transition(session, to: .readyForReview)
        XCTAssertEqual(result.status, .crashed)
        XCTAssertEqual(result.lastActiveAt, session.lastActiveAt)
    }

    func testLegalTransitionUpdatesStatusAndTimestamp() {
        let session = makeSession(status: nil)
        let later = session.createdAt.addingTimeInterval(60)
        let result = machine.transition(session, to: .working, now: later)
        XCTAssertEqual(result.status, .working)
        XCTAssertEqual(result.lastActiveAt, later)
    }

    func testLeavingWaitingClearsItsReason() {
        var session = makeSession(status: .waitingForInput)
        session.waitingReason = .permission

        let result = machine.transition(session, to: .working)

        XCTAssertEqual(result.status, .working)
        XCTAssertNil(result.waitingReason)
    }
}

final class BranchNamingTests: XCTestCase {
    func testDisplayNameHidesFlotillaPrefixAndGeneratedSuffix() {
        XCTAssertEqual(
            BranchNaming.displayName(for: "flotilla/fix-login-bug-a1b2c3d4"),
            "fix-login-bug"
        )
    }

    func testDisplayNameHidesPrefixForAgentChosenBranchWithoutSuffix() {
        XCTAssertEqual(
            BranchNaming.displayName(for: "flotilla/agent-chosen-slug"),
            "agent-chosen-slug"
        )
    }

    func testDisplayNameLeavesUnmanagedBranchUnchanged() {
        XCTAssertEqual(
            BranchNaming.displayName(for: "feature/fix-login-bug-a1b2c3d4"),
            "feature/fix-login-bug-a1b2c3d4"
        )
    }
}

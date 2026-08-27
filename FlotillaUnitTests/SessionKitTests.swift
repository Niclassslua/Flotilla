import XCTest
import SessionKit

final class SessionStatusMachineTests: XCTestCase {
    private let machine = SessionStatusMachine()

    private func makeSession(status: SessionStatus) -> Session {
        Session(
            title: "Test",
            goal: "Do the thing",
            agent: .claudeCode,
            projectID: nil,
            workingDirectory: URL(fileURLWithPath: "/tmp"),
            status: status
        )
    }

    // Every legal transition, exhaustively.
    func testLegalTransitions() {
        let legalPairs: [(SessionStatus, SessionStatus)] = [
            (.idle, .working),
            (.idle, .waitingForInput),
            (.idle, .ready),
            (.idle, .finished),
            (.idle, .crashed),
            (.working, .idle),
            (.working, .waitingForInput),
            (.working, .ready),
            (.working, .finished),
            (.working, .crashed),
            (.waitingForInput, .working),
            (.waitingForInput, .idle),
            (.waitingForInput, .ready),
            (.waitingForInput, .finished),
            (.waitingForInput, .crashed),
            (.ready, .working),
            (.ready, .waitingForInput),
            (.ready, .idle),
            (.ready, .finished),
            (.ready, .crashed),
            (.crashed, .working),
            (.finished, .working),
        ]
        for (from, to) in legalPairs {
            XCTAssertTrue(machine.canTransition(from: from, to: to), "\(from) -> \(to) should be legal")
        }
    }

    /// Both terminal states are re-enterable only through `.working`, the
    /// status an explicit restart moves a session to. Nothing else may
    /// reopen them — in particular no output-derived status, which is what
    /// keeps a stray repaint from resurrecting a session that is done.
    func testTerminalStatesOnlyReopenViaExplicitRestart() {
        for target in SessionStatus.allCases {
            for terminal: SessionStatus in [.finished, .crashed] {
                XCTAssertEqual(
                    machine.canTransition(from: terminal, to: target),
                    target == .working,
                    "\(terminal) may transition only to working"
                )
            }
        }
    }

    func testSelfTransitionsAreIllegal() {
        for status in SessionStatus.allCases {
            XCTAssertFalse(machine.canTransition(from: status, to: status), "\(status) -> \(status) should be illegal")
        }
    }

    func testIllegalTransitionLeavesSessionUnchanged() {
        let session = makeSession(status: .finished)
        // A finished session cannot drift back to idle on its own.
        let result = machine.transition(session, to: .idle)
        XCTAssertEqual(result.status, .finished)
        XCTAssertEqual(result.lastActiveAt, session.lastActiveAt)
    }

    func testLegalTransitionUpdatesStatusAndTimestamp() {
        let session = makeSession(status: .idle)
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

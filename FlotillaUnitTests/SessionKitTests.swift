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
            (.idle, .finished),
            (.idle, .crashed),
            (.working, .idle),
            (.working, .waitingForInput),
            (.working, .finished),
            (.working, .crashed),
            (.waitingForInput, .working),
            (.waitingForInput, .idle),
            (.waitingForInput, .finished),
            (.waitingForInput, .crashed),
            (.crashed, .working),
        ]
        for (from, to) in legalPairs {
            XCTAssertTrue(machine.canTransition(from: from, to: to), "\(from) -> \(to) should be legal")
        }
    }

    func testFinishedIsTerminalAndCrashedOnlyAllowsExplicitRestart() {
        for target in SessionStatus.allCases {
            XCTAssertFalse(machine.canTransition(from: .finished, to: target), "finished -> \(target) must be illegal")
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

    func testIllegalTransitionLeavesSessionUnchanged() {
        let session = makeSession(status: .idle)
        // idle -> waitingForInput is not a direct legal edge.
        let result = machine.transition(session, to: .waitingForInput)
        XCTAssertEqual(result.status, .idle)
        XCTAssertEqual(result.lastActiveAt, session.lastActiveAt)
    }

    func testLegalTransitionUpdatesStatusAndTimestamp() {
        let session = makeSession(status: .idle)
        let later = session.createdAt.addingTimeInterval(60)
        let result = machine.transition(session, to: .working, now: later)
        XCTAssertEqual(result.status, .working)
        XCTAssertEqual(result.lastActiveAt, later)
    }
}

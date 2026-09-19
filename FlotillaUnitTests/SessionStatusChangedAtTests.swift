import XCTest
import SessionKit
import PersistenceKit
@testable import Flotilla

final class SessionStatusChangedAtTests: XCTestCase {
    func testStatusChangedAtRoundTripsThroughPersistence() throws {
        let repo = try GRDBSessionRepository()
        let project = Project(name: "flotilla", rootPath: URL(fileURLWithPath: "/tmp/flotilla"))
        try repo.save(project)
        let now = Date()
        var session = Session(
            title: "Test",
            goal: "Do a thing",
            agent: .claudeCode,
            projectID: project.id,
            workingDirectory: project.rootPath,
            status: .waitingForInput,
            waitingReason: .permission,
            statusChangedAt: now
        )
        try repo.save(session)

        let (_, loadedSessions) = try repo.loadAll()
        let loaded = try XCTUnwrap(loadedSessions.first { $0.id == session.id })
        XCTAssertEqual(loaded.statusChangedAt?.timeIntervalSince1970 ?? 0, now.timeIntervalSince1970, accuracy: 1)

        // A session with no statusChangedAt (pre-migration data) round-trips
        // as nil rather than crashing the decode.
        session.statusChangedAt = nil
        try repo.save(session)
        let (_, reloaded) = try repo.loadAll()
        XCTAssertNil(reloaded.first { $0.id == session.id }?.statusChangedAt)
    }

    func testTransitionStampsStatusChangedAt() {
        let machine = SessionStatusMachine()
        let session = Session(
            title: "Test",
            goal: "Do a thing",
            agent: .claudeCode,
            projectID: nil,
            workingDirectory: URL(fileURLWithPath: "/tmp"),
            status: nil
        )
        XCTAssertNil(session.statusChangedAt)
        let now = Date()
        let updated = machine.transition(session, to: .working, now: now)
        XCTAssertEqual(updated.statusChangedAt, now)
    }

    /// A self-transition (same status, e.g. a waiting reason update) must not
    /// touch `statusChangedAt` — "waiting since" should reflect when waiting
    /// *started*, not the most recent reason change within it.
    func testSelfTransitionDoesNotAdvanceStatusChangedAt() {
        let machine = SessionStatusMachine()
        let started = Date(timeIntervalSince1970: 1_000)
        let session = Session(
            title: "Test",
            goal: "Do a thing",
            agent: .claudeCode,
            projectID: nil,
            workingDirectory: URL(fileURLWithPath: "/tmp"),
            status: .waitingForInput,
            waitingReason: .question,
            statusChangedAt: started
        )
        let updated = machine.transition(session, to: .waitingForInput, now: Date(timeIntervalSince1970: 2_000))
        XCTAssertEqual(updated.statusChangedAt, started)
    }
}

import XCTest
import CompanionKit
import SessionKit
@testable import FlotillaCompanion

/// What the fleet Live Activity shows, and when it runs at all.
@MainActor
final class FleetActivitySnapshotTests: XCTestCase {
    private let now = Date(timeIntervalSinceReferenceDate: 800_000_000)
    private let mac = MacHost(id: "studio", name: "Studio", connection: .connected(path: .lan, address: "10.0.0.2"), lastSeen: .now)

    private func session(
        _ title: String,
        _ status: SessionStatus?,
        minutesAgo: Double = 1,
        failure: String? = nil,
        reviewAcknowledged: Bool = false
    ) -> CompanionSession {
        CompanionSession(
            id: UUID(), title: title, agent: .claudeCode, model: "opus", status: status,
            hasWorktree: false, isProcessLive: true, updatedAt: now.addingTimeInterval(-minutesAgo * 60),
            failure: failure, reviewAcknowledged: reviewAcknowledged
        )
    }

    private func snapshot(_ sessions: [CompanionSession], mac: MacHost? = nil) -> FleetActivitySnapshot {
        FleetActivitySnapshot(mac: mac ?? self.mac, sessions: sessions, goesStale: false)
    }

    func testMostUrgentFirstThenMostRecent() {
        let snapshot = snapshot([
            session("ready", .readyForReview),
            session("working old", .working, minutesAgo: 30),
            session("crashed", .crashed),
            session("working new", .working, minutesAgo: 2),
            session("waiting", .waitingForInput, minutesAgo: 50),
        ])
        XCTAssertEqual(snapshot.state.sessions.map(\.title), ["waiting", "crashed", "working new", "working old", "ready"])
    }

    func testLeavesOutUnstartedAndAcknowledgedReviews() {
        let snapshot = snapshot([
            session("unstarted", nil),
            session("seen", .readyForReview, reviewAcknowledged: true),
            session("working", .working),
        ])
        XCTAssertEqual(snapshot.state.sessions.map(\.title), ["working"])
        XCTAssertEqual(snapshot.state.activeCount, 1)
    }

    func testFailedTurnNeedsYouEvenWhenReady() {
        let snapshot = snapshot([session("quota", .readyForReview, failure: "quota exceeded", reviewAcknowledged: true)])
        XCTAssertEqual(snapshot.state.sessions.first?.status, .waiting)
        XCTAssertEqual(snapshot.state.sessions.first?.detail, "quota exceeded")
        XCTAssertTrue(snapshot.isActive)
    }

    func testOnlyReviewsLeftEndsTheActivity() {
        let snapshot = snapshot([session("ready", .readyForReview)])
        XCTAssertFalse(snapshot.isActive)
        XCTAssertTrue(snapshot.urgentSessionIDs.isEmpty)
    }

    func testCapsSessionsButCountsThemAll() {
        let sessions = (0..<12).map { session("s\($0)", .working, minutesAgo: Double($0)) }
        let snapshot = snapshot(sessions)
        XCTAssertEqual(snapshot.state.sessions.count, FleetActivityAttributes.maxSessions)
        XCTAssertEqual(snapshot.state.activeCount, 12)
    }

    func testUnreachableMacIsNotLive() {
        var offline = mac
        offline.connection = .unreachable
        XCTAssertFalse(snapshot([session("working", .working)], mac: offline).state.isLive)
        XCTAssertTrue(snapshot([session("working", .working)]).state.isLive)
    }

    func testPagesSessionsByPageSize() {
        let sessions = (0..<7).map { session("s\($0)", .working, minutesAgo: Double($0)) }
        var state = snapshot(sessions).state
        XCTAssertEqual(state.pageCount, 3) // 7 sessions, pageSize 3 → 3 pages (3/3/1)
        XCTAssertEqual(state.visibleSessions.map(\.title), ["s0", "s1", "s2"])

        state.pageIndex = 1
        XCTAssertEqual(state.visibleSessions.map(\.title), ["s3", "s4", "s5"])

        state.pageIndex = 2
        XCTAssertEqual(state.visibleSessions.map(\.title), ["s6"])
    }

    func testPageIndexWrapsAroundPageCount() {
        let sessions = (0..<4).map { session("s\($0)", .working, minutesAgo: Double($0)) }
        var state = snapshot(sessions).state
        XCTAssertEqual(state.pageCount, 2)

        state.pageIndex = 2 // one full lap past the last page
        XCTAssertEqual(state.visibleSessions.map(\.title), ["s0", "s1", "s2"])
    }

    func testSinglePageNeverEmpty() {
        let state = snapshot([session("only", .working)]).state
        XCTAssertEqual(state.pageCount, 1)
        XCTAssertEqual(state.visibleSessions.map(\.title), ["only"])
    }
}

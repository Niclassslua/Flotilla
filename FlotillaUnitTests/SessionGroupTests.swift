import XCTest
import SessionKit
@testable import Flotilla

/// The group is the axis the session group bar adds: General had no
/// representation at all before it, because `SessionScope.projectID == nil`
/// already meant "every project" and so could never also mean "no project".
@MainActor
final class SessionGroupTests: XCTestCase {

    private let alpha = UUID()
    private let beta = UUID()

    private func session(_ title: String, project: UUID? = nil, status: SessionStatus? = nil) -> Session {
        var made = Session(
            title: title,
            goal: "g",
            agent: .claudeCode,
            projectID: project,
            workingDirectory: URL(fileURLWithPath: "/tmp/checkout")
        )
        made.status = status
        return made
    }

    private var fleet: [Session] {
        [
            session("a", project: alpha),
            session("b", project: alpha, status: .waitingForInput),
            session("c", project: beta),
            session("d"),
            session("e", status: .waitingForInput)
        ]
    }

    // MARK: - Filtering

    func testAllKeepsEverySession() {
        let scope = SessionScope(group: .all)
        XCTAssertEqual(scope.apply(to: fleet).count, 5)
        XCTAssertTrue(scope.isEverything)
    }

    func testProjectKeepsOnlyThatProject() {
        let titles = SessionScope(group: .project(alpha)).apply(to: fleet).map(\.title)
        XCTAssertEqual(titles, ["a", "b"])
    }

    /// The case the old `projectID: UUID?` could not express.
    func testGeneralKeepsOnlySessionsWithNoProject() {
        let titles = SessionScope(group: .general).apply(to: fleet).map(\.title)
        XCTAssertEqual(titles, ["d", "e"])
    }

    func testGeneralIsNotEverything() {
        XCTAssertFalse(SessionScope(group: .general).isEverything)
        XCTAssertFalse(SessionScope(group: .project(alpha)).isEverything)
    }

    /// A group narrows the fleet and a smart list narrows it again — the two
    /// axes compose rather than overriding each other.
    func testGroupAndSmartListNarrowTogether() {
        XCTAssertEqual(
            SessionScope(group: .project(alpha), smartList: .needsYou).apply(to: fleet).map(\.title),
            ["b"]
        )
        XCTAssertEqual(
            SessionScope(group: .general, smartList: .needsYou).apply(to: fleet).map(\.title),
            ["e"]
        )
    }

    /// The empty state has to name the narrowing responsible, including the
    /// two new General arms.
    func testEmptyDescriptionNamesTheNarrowing() {
        XCTAssertTrue(SessionScope(group: .general).emptyDescription.contains("outside a project"))
        XCTAssertTrue(
            SessionScope(group: .general, smartList: .working).emptyDescription.contains("working")
        )
        XCTAssertTrue(SessionScope(group: .project(alpha)).emptyDescription.contains("project"))
    }

    // MARK: - Persistence round trip

    func testRawValueRoundTrips() {
        for group in [SessionGroup.all, .general, .project(alpha)] {
            XCTAssertEqual(SessionGroup(rawValue: group.rawValue), group)
        }
    }

    /// A persisted group naming a project that has since been deleted should
    /// land the user in the whole fleet, not on an empty screen with no chip
    /// to explain it.
    func testUnparseableRawValueFallsBackToAll() {
        XCTAssertEqual(SessionGroup(rawValue: "not-a-uuid"), .all)
        XCTAssertEqual(SessionGroup(rawValue: ""), .all)
    }

    // MARK: - Navigator

    func testNavigatorAppliesTheGroupInCollectionScopes() {
        let navigator = WorkspaceNavigator()
        navigator.sessionGroup = .general

        navigator.selection = .allSessions
        XCTAssertEqual(navigator.sessionScope, SessionScope(group: .general, smartList: nil))

        navigator.selection = .smartList(.working)
        XCTAssertEqual(navigator.sessionScope, SessionScope(group: .general, smartList: .working))
    }

    /// Project scope comes from the navigator, not the bar: the group bar is
    /// not on screen in a project workspace, so a stale chip must not filter
    /// one from off screen.
    func testProjectSelectionWinsOverTheGroup() {
        let navigator = WorkspaceNavigator()
        navigator.sessionGroup = .general
        navigator.selection = .project(alpha)
        XCTAssertEqual(navigator.sessionScope, SessionScope(group: .project(alpha), smartList: nil))
    }

    func testPruningDropsAGroupWhoseProjectIsGone() {
        let navigator = WorkspaceNavigator()
        navigator.sessionGroup = .project(alpha)

        navigator.pruneSessionGroup(against: [alpha, beta])
        XCTAssertEqual(navigator.sessionGroup, .project(alpha))

        navigator.pruneSessionGroup(against: [beta])
        XCTAssertEqual(navigator.sessionGroup, .all)
    }

    func testPruningLeavesAllAndGeneralAlone() {
        let navigator = WorkspaceNavigator()
        navigator.sessionGroup = .general
        navigator.pruneSessionGroup(against: [])
        XCTAssertEqual(navigator.sessionGroup, .general)
    }
}

/// The one elapsed-time helper the tiles, the session bar and the cards now
/// share — it had been copied twice with the same boundaries.
final class SessionElapsedTests: XCTestCase {

    func testDetailedAgeRetainsMinutesAcrossHoursAndDays() {
        let start = Date(timeIntervalSince1970: 0)
        let cases: [(TimeInterval, String)] = [
            (-30, "0s"), (0, "0s"), (59, "59s"), (60, "1m"),
            (3599, "59m"), (3600, "1h 0m"), (7140, "1h 59m"),
            (86_399, "23h 59m"), (86_400, "1d 0h 0m"),
            (101_520, "1d 4h 12m")
        ]
        for (seconds, expected) in cases {
            XCTAssertEqual(
                SessionElapsed.detailedSince(start, now: start.addingTimeInterval(seconds)),
                expected
            )
        }
    }

    private func text(_ seconds: TimeInterval) -> String {
        let now = Date()
        return SessionElapsed.since(now.addingTimeInterval(-seconds), now: now)
    }

    func testBucketsAtEachBoundary() {
        XCTAssertEqual(text(0), "0s")
        XCTAssertEqual(text(59), "59s")
        XCTAssertEqual(text(60), "1m")
        XCTAssertEqual(text(3599), "59m")
        XCTAssertEqual(text(3600), "1h")
        XCTAssertEqual(text(86_399), "23h")
        XCTAssertEqual(text(86_400), "1d")
    }

    /// A session whose `createdAt` is slightly in the future (clock skew
    /// across a restore) should read as brand new, not as a negative age.
    func testFutureStartReadsAsZero() {
        XCTAssertEqual(text(-30), "0s")
    }
}

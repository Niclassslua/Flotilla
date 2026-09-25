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

    func testGroupAndSmartListFiltering() {
        XCTAssertEqual(SessionScope(group: .all).apply(to: fleet).count, 5)
        XCTAssertTrue(SessionScope(group: .all).isEverything)
        XCTAssertEqual(SessionScope(group: .project(alpha)).apply(to: fleet).map(\.title), ["a", "b"])
        XCTAssertEqual(SessionScope(group: .general).apply(to: fleet).map(\.title), ["d", "e"])
        XCTAssertEqual(
            SessionScope(group: .project(alpha), smartList: .needsYou).apply(to: fleet).map(\.title),
            ["b"]
        )
        XCTAssertEqual(
            SessionScope(group: .general, smartList: .needsYou).apply(to: fleet).map(\.title),
            ["e"]
        )
    }

    // MARK: - Persistence round trip

    func testRawValueRoundTripsAndFallsBack() {
        for group in [SessionGroup.all, .general, .project(alpha)] {
            XCTAssertEqual(SessionGroup(rawValue: group.rawValue), group)
        }
        XCTAssertEqual(SessionGroup(rawValue: "not-a-uuid"), .all)
        XCTAssertEqual(SessionGroup(rawValue: ""), .all)
    }

    // MARK: - Navigator

    func testNavigatorScopePruningAndProjectOverride() {
        let navigator = WorkspaceNavigator()
        navigator.sessionGroup = .general

        navigator.selection = .allSessions
        XCTAssertEqual(navigator.sessionScope, SessionScope(group: .general, smartList: nil))
        navigator.selection = .smartList(.working)
        XCTAssertEqual(navigator.sessionScope, SessionScope(group: .general, smartList: .working))

        navigator.selection = .project(alpha)
        XCTAssertEqual(navigator.sessionScope, SessionScope(group: .project(alpha), smartList: nil))

        navigator.sessionGroup = .project(alpha)
        navigator.pruneSessionGroup(against: [alpha, beta])
        XCTAssertEqual(navigator.sessionGroup, .project(alpha))
        navigator.pruneSessionGroup(against: [beta])
        XCTAssertEqual(navigator.sessionGroup, .all)

        navigator.sessionGroup = .general
        navigator.pruneSessionGroup(against: [])
        XCTAssertEqual(navigator.sessionGroup, .general)
    }
}

/// The one elapsed-time helper the tiles, the session bar and the cards now
/// share — it had been copied twice with the same boundaries.
final class SessionElapsedTests: XCTestCase {

    func testElapsedFormattingBoundaries() {
        let start = Date(timeIntervalSince1970: 0)
        let detailed: [(TimeInterval, String)] = [
            (-30, "0s"), (0, "0s"), (59, "59s"), (60, "1m"),
            (3599, "59m"), (3600, "1h 0m"), (7140, "1h 59m"),
            (86_399, "23h 59m"), (86_400, "1d 0h 0m"),
            (101_520, "1d 4h 12m")
        ]
        for (seconds, expected) in detailed {
            XCTAssertEqual(
                SessionElapsed.detailedSince(start, now: start.addingTimeInterval(seconds)),
                expected
            )
        }

        let now = Date()
        func text(_ seconds: TimeInterval) -> String {
            SessionElapsed.since(now.addingTimeInterval(-seconds), now: now)
        }
        XCTAssertEqual(text(0), "0s")
        XCTAssertEqual(text(59), "59s")
        XCTAssertEqual(text(60), "1m")
        XCTAssertEqual(text(3599), "59m")
        XCTAssertEqual(text(3600), "1h")
        XCTAssertEqual(text(86_399), "23h")
        XCTAssertEqual(text(86_400), "1d")
        XCTAssertEqual(text(-30), "0s", "future start reads as brand new")
    }
}

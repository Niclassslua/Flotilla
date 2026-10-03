import XCTest
import Observation
import SessionKit
@testable import Flotilla

@MainActor
final class FleetAttentionTests: XCTestCase {
    @Observable @MainActor
    final class Fleet {
        var sessions: [Session] = []
        var badgeEnabled = true
    }

    private func session(_ title: String, _ status: SessionStatus?) -> Session {
        Session(
            title: title,
            goal: "",
            agent: .claudeCode,
            projectID: nil,
            workingDirectory: URL(fileURLWithPath: "/tmp"),
            status: status
        )
    }

    /// The badge must track waiting sessions as they come and go, count
    /// nothing else, and clear when the user turns it off — a stale badge
    /// after the last session is answered is the failure a user would see.
    func testDockBadgeFollowsWaitingSessionsAndSetting() async {
        let fleet = Fleet()
        fleet.sessions = [
            session("waiting", .waitingForInput),
            session("ready", .readyForReview),
            session("crashed", .crashed),
            session("working", .working),
        ]
        var applied: [String?] = []
        let controller = DockBadgeController(
            sessions: { fleet.sessions },
            isEnabled: { fleet.badgeEnabled },
            apply: { applied.append($0) }
        )
        controller.start()
        XCTAssertEqual(applied, ["1"])

        fleet.sessions.append(session("second waiting", .waitingForInput))
        await waitUntil { applied.last == "2" }

        fleet.sessions = fleet.sessions.filter { $0.status != .waitingForInput }
        await waitUntil { applied.last == .some(nil) }

        fleet.sessions.append(session("third waiting", .waitingForInput))
        await waitUntil { applied.last == "1" }

        fleet.badgeEnabled = false
        await waitUntil { applied.last == .some(nil) }
        XCTAssertEqual(applied, ["1", "2", nil, "1", nil])
    }

    private func waitUntil(_ condition: () -> Bool, file: StaticString = #filePath, line: UInt = #line) async {
        let deadline = Date().addingTimeInterval(2)
        while !condition() {
            if Date() > deadline {
                XCTFail("condition not met within 2s", file: file, line: line)
                return
            }
            await Task.yield()
        }
    }
}

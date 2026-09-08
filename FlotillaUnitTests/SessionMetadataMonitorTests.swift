import XCTest
import AgentKit
import SessionKit
@testable import Flotilla

/// The monitor exists so metadata polling has an owner that can be cancelled.
/// These pin the lifetime rules AppStore depends on: a restart supersedes the
/// previous run, deletion stops the work, and a result computed for an older
/// run is rejected rather than applied to the session that replaced it.
@MainActor
final class SessionMetadataMonitorTests: XCTestCase {
    private func fastTiming() -> SessionMetadataMonitor.Timing {
        SessionMetadataMonitor.Timing(
            burstDelays: [.milliseconds(5)],
            steadyInterval: .milliseconds(5),
            giveUpAfter: .seconds(10),
            fallbackAfter: .milliseconds(10),
            pollChunk: .milliseconds(5)
        )
    }

    func testStartingDiscoveryAgainReplacesThePreviousTask() async throws {
        let monitor = SessionMetadataMonitor(timing: fastTiming())
        let sessionID = UUID()
        let first = Counter()
        let second = Counter()

        monitor.startDiscovery(for: sessionID, isActive: { true }, refresh: { first.increment() })
        monitor.startDiscovery(for: sessionID, isActive: { true }, refresh: { second.increment() })

        try await Task.sleep(for: .milliseconds(120))
        monitor.cancelAll()

        XCTAssertEqual(first.value, 0, "the superseded task must not keep refreshing")
        XCTAssertGreaterThan(second.value, 0)
    }

    func testCancellingStopsFurtherRefreshes() async throws {
        let monitor = SessionMetadataMonitor(timing: fastTiming())
        let sessionID = UUID()
        let refreshes = Counter()

        monitor.startDiscovery(for: sessionID, isActive: { true }, refresh: { refreshes.increment() })
        try await Task.sleep(for: .milliseconds(60))
        monitor.cancel(sessionID)
        let atCancellation = refreshes.value

        try await Task.sleep(for: .milliseconds(80))
        XCTAssertEqual(refreshes.value, atCancellation)
    }

    func testAnInactiveSessionEndsThePollLoop() async throws {
        let monitor = SessionMetadataMonitor(timing: fastTiming())
        let refreshes = Counter()

        monitor.startDiscovery(for: UUID(), isActive: { false }, refresh: { refreshes.increment() })
        try await Task.sleep(for: .milliseconds(80))

        XCTAssertEqual(refreshes.value, 0)
    }

    func testGenerationIsStableUntilCancellationAndStaleResultsAreRejected() {
        let monitor = SessionMetadataMonitor()
        let sessionID = UUID()

        let generation = monitor.generation(for: sessionID)
        XCTAssertEqual(monitor.generation(for: sessionID), generation)
        XCTAssertTrue(monitor.isCurrent(generation, for: sessionID))

        // A restart cancels, which is what makes the next run a new one.
        monitor.cancel(sessionID)
        let restarted = monitor.generation(for: sessionID)

        XCTAssertNotEqual(restarted, generation)
        XCTAssertFalse(monitor.isCurrent(generation, for: sessionID),
                       "a result from the previous run must not apply to the restarted session")
        XCTAssertTrue(monitor.isCurrent(restarted, for: sessionID))
    }

    func testSelfReportAppliesTheDescriptorItReads() async throws {
        let descriptor = AgentSelfReportDescriptor(title: "Reported", branch: "feature", worktreePath: "/tmp/wt")
        var dependencies = SessionMetadataMonitor.Dependencies()
        dependencies.readDescriptor = { _, _ in descriptor }
        let monitor = SessionMetadataMonitor(timing: fastTiming(), dependencies: dependencies)

        let applied = Box<AgentSelfReportDescriptor?>(nil)
        monitor.startSelfReport(
            for: UUID(),
            path: URL(fileURLWithPath: "/tmp/report.json"),
            wantsWorktree: false,
            exists: { true },
            isActive: { true },
            fallback: { nil },
            apply: { descriptor, _ in applied.value = descriptor }
        )

        try await Task.sleep(for: .milliseconds(60))
        XCTAssertEqual(applied.value?.title, "Reported")
    }

    func testSelfReportForADeletedSessionIsNotApplied() async throws {
        let descriptor = AgentSelfReportDescriptor(title: "Reported", branch: nil, worktreePath: nil)
        var dependencies = SessionMetadataMonitor.Dependencies()
        dependencies.readDescriptor = { _, _ in descriptor }
        let monitor = SessionMetadataMonitor(timing: fastTiming(), dependencies: dependencies)

        let applied = Box<AgentSelfReportDescriptor?>(nil)
        monitor.startSelfReport(
            for: UUID(),
            path: URL(fileURLWithPath: "/tmp/report.json"),
            wantsWorktree: false,
            exists: { false },
            isActive: { true },
            fallback: { nil },
            apply: { descriptor, _ in applied.value = descriptor }
        )

        try await Task.sleep(for: .milliseconds(60))
        XCTAssertNil(applied.value)
    }
}

@MainActor
private final class Counter {
    private(set) var value = 0
    func increment() { value += 1 }
}

@MainActor
private final class Box<T> {
    var value: T
    init(_ value: T) { self.value = value }
}

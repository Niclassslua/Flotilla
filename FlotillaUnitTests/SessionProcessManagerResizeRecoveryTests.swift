import XCTest
import SessionKit
import ProcessKit
import GitKit
import PersistenceKit
import SettingsKit
import TerminalKit
import HooksKit
@testable import Flotilla

@MainActor
final class SessionProcessManagerResizeRecoveryTests: XCTestCase {
    /// Production re-probes with a doubling backoff before believing tmux
    /// disagrees, because a false mismatch costs a PTY relaunch. These tests
    /// are about *what* recovery does, not how patiently it waits, so they run
    /// the same logic with the delays collapsed.
    private func makeManager(
        factory: RecordingProcessFactory,
        probe: MockTmuxClientProbe,
        attempts: Int = 2
    ) -> SessionProcessManager {
        SessionProcessManager(
            locator: AppLayerExecutableLocator(
                executable: URL(fileURLWithPath: "/usr/bin/env"),
                tmuxExecutable: URL(fileURLWithPath: "/usr/bin/tmux")
            ),
            processFactory: factory,
            tmuxServerProbe: AppLayerTmuxServerProbe(usable: true),
            tmuxClientProbe: probe,
            resizeVerification: .init(attempts: attempts, baseDelay: .milliseconds(20))
        )
    }

    func testResizeMismatchTriggersReattach() async throws {
        let factory = RecordingProcessFactory()
        let probe = MockTmuxClientProbe()
        let manager = makeManager(factory: factory, probe: probe)

        let session = Session(
            title: "Mismatch",
            goal: "Test",
            agent: .claudeCode,
            projectID: nil,
            workingDirectory: URL(fileURLWithPath: "/tmp"),
            status: .working
        )
        let sessionName = TmuxSessionWrapping.sessionName(for: session.id)
        probe.stubbedSizes[sessionName] = PTYSize(cols: 80, rows: 25) // Stale size

        let initialProcess = try manager.start(session: session, deliverGoal: false)
        XCTAssertEqual(factory.processes.count, 1)

        // Request verification for expected size 199x47
        manager.verifyAndRecoverResize(sessionID: session.id, expectedSize: PTYSize(cols: 199, rows: 47))

        // Wait for debounce (250ms) + async probe
        for _ in 0..<20 {
            if factory.processes.count > 1 { break }
            try await Task.sleep(for: .milliseconds(50))
        }

        XCTAssertEqual(factory.processes.count, 2, "Mismatch must trigger reattach (a fresh PTY process)")
        let replacement = manager.process(for: session.id)
        XCTAssertTrue(replacement !== initialProcess, "Replacement process must be distinct from initial")
    }

    func testResizeMatchDoesNotTriggerReattach() async throws {
        let factory = RecordingProcessFactory()
        let probe = MockTmuxClientProbe()
        let manager = makeManager(factory: factory, probe: probe)

        let session = Session(
            title: "Match",
            goal: "Test",
            agent: .claudeCode,
            projectID: nil,
            workingDirectory: URL(fileURLWithPath: "/tmp"),
            status: .working
        )
        let sessionName = TmuxSessionWrapping.sessionName(for: session.id)
        probe.stubbedSizes[sessionName] = PTYSize(cols: 199, rows: 47) // Matching size

        let initialProcess = try manager.start(session: session, deliverGoal: false)
        XCTAssertEqual(factory.processes.count, 1)

        manager.verifyAndRecoverResize(sessionID: session.id, expectedSize: PTYSize(cols: 199, rows: 47))
        try await Task.sleep(for: .milliseconds(350))

        XCTAssertEqual(factory.processes.count, 1, "Matching size must NOT trigger reattach")
        XCTAssertTrue(manager.process(for: session.id) === initialProcess)
    }

    func testReattachRecoveryRateLimit() async throws {
        let factory = RecordingProcessFactory()
        let probe = MockTmuxClientProbe()
        let manager = makeManager(factory: factory, probe: probe)

        let session = Session(
            title: "RateLimit",
            goal: "Test",
            agent: .claudeCode,
            projectID: nil,
            workingDirectory: URL(fileURLWithPath: "/tmp"),
            status: .working
        )
        let sessionName = TmuxSessionWrapping.sessionName(for: session.id)
        probe.stubbedSizes[sessionName] = PTYSize(cols: 80, rows: 25)

        _ = try manager.start(session: session, deliverGoal: false)

        var failureMessage: String?
        // 1st mismatch -> reattach #1
        manager.verifyAndRecoverResize(sessionID: session.id, expectedSize: PTYSize(cols: 100, rows: 30)) { msg in
            failureMessage = msg
        }
        for _ in 0..<20 {
            if factory.processes.count >= 2 { break }
            try await Task.sleep(for: .milliseconds(50))
        }
        XCTAssertEqual(factory.processes.count, 2)
        XCTAssertNil(failureMessage)

        // 2nd mismatch -> reattach #2
        manager.verifyAndRecoverResize(sessionID: session.id, expectedSize: PTYSize(cols: 120, rows: 40)) { msg in
            failureMessage = msg
        }
        for _ in 0..<20 {
            if factory.processes.count >= 3 { break }
            try await Task.sleep(for: .milliseconds(50))
        }
        XCTAssertEqual(factory.processes.count, 3)
        XCTAssertNil(failureMessage)

        // 3rd mismatch -> cap hit! Should not reattach, should invoke onRecoveryFailure
        manager.verifyAndRecoverResize(sessionID: session.id, expectedSize: PTYSize(cols: 140, rows: 50)) { msg in
            failureMessage = msg
        }
        try await Task.sleep(for: .milliseconds(350))
        XCTAssertEqual(factory.processes.count, 3, "Third attempt within 60s must be capped")
        XCTAssertNotNil(failureMessage, "Failure message must be surfaced when recovery limit is reached")
    }

    /// The bug this guards: a single probe 250 ms after the resize often
    /// caught tmux mid-update, and the "recovery" for that was to tear down
    /// and relaunch the PTY — which came back at the hardcoded launch size, so
    /// the next probe mismatched too and the rate limit stranded the session.
    /// A size that settles must never cost a reattach.
    func testTransientMismatchThatSettlesDoesNotReattach() async throws {
        let factory = RecordingProcessFactory()
        let probe = MockTmuxClientProbe()
        let manager = makeManager(factory: factory, probe: probe, attempts: 4)

        let session = Session(
            title: "Settles",
            goal: "Test",
            agent: .claudeCode,
            projectID: nil,
            workingDirectory: URL(fileURLWithPath: "/tmp"),
            status: .working
        )
        let sessionName = TmuxSessionWrapping.sessionName(for: session.id)
        let expected = PTYSize(cols: 199, rows: 47)
        // tmux reports the old size once, then catches up.
        probe.settlingSizes[sessionName] = [PTYSize(cols: 80, rows: 25)]
        probe.stubbedSizes[sessionName] = expected

        let initialProcess = try manager.start(session: session, deliverGoal: false)

        var failureMessage: String?
        manager.verifyAndRecoverResize(sessionID: session.id, expectedSize: expected) { msg in
            failureMessage = msg
        }
        try await Task.sleep(for: .milliseconds(500))

        XCTAssertGreaterThanOrEqual(probe.clientSizeCalls.count, 2, "A disagreeing probe must be retried, not believed")
        XCTAssertEqual(factory.processes.count, 1, "A size that settles must not trigger a reattach")
        XCTAssertTrue(manager.process(for: session.id) === initialProcess)
        XCTAssertNil(failureMessage)
    }

    /// A reattach that relaunches at the hardcoded default guarantees the next
    /// verification mismatches, which is what turned one bad probe into a
    /// permanently mis-sized session.
    func testReattachRelaunchesAtTheLastVerifiedSizeNotTheDefault() async throws {
        let factory = RecordingProcessFactory()
        let probe = MockTmuxClientProbe()
        let manager = makeManager(factory: factory, probe: probe)

        let session = Session(
            title: "ReattachSize",
            goal: "Test",
            agent: .claudeCode,
            projectID: nil,
            workingDirectory: URL(fileURLWithPath: "/tmp"),
            status: .working
        )
        let sessionName = TmuxSessionWrapping.sessionName(for: session.id)
        probe.stubbedSizes[sessionName] = PTYSize(cols: 80, rows: 25)
        let expected = PTYSize(cols: 199, rows: 47)

        _ = try manager.start(session: session, deliverGoal: false)
        XCTAssertEqual(factory.processes.first?.lastSize, PTYSize(cols: 100, rows: 30))

        manager.verifyAndRecoverResize(sessionID: session.id, expectedSize: expected)
        for _ in 0..<40 {
            if factory.processes.count > 1 { break }
            try await Task.sleep(for: .milliseconds(25))
        }

        XCTAssertEqual(factory.processes.count, 2)
        XCTAssertEqual(
            factory.processes.last?.lastSize,
            expected,
            "The replacement PTY must start at the size we are trying to reach, not the launch default"
        )
    }

    func testRefreshTmuxClientCallsProbe() async throws {
        let factory = RecordingProcessFactory()
        let probe = MockTmuxClientProbe()
        let manager = makeManager(factory: factory, probe: probe)

        let session = Session(
            title: "RefreshTest",
            goal: "Test",
            agent: .claudeCode,
            projectID: nil,
            workingDirectory: URL(fileURLWithPath: "/tmp"),
            status: .working
        )
        _ = try manager.start(session: session, deliverGoal: false)

        manager.refreshTmuxClient(for: session.id)

        for _ in 0..<20 {
            if !probe.refreshClientCalls.isEmpty { break }
            try await Task.sleep(for: .milliseconds(20))
        }

        XCTAssertEqual(probe.refreshClientCalls.count, 1)
        XCTAssertEqual(probe.refreshClientCalls.first?.sessionName, TmuxSessionWrapping.sessionName(for: session.id))
    }
}

import XCTest
import SessionKit
import ProcessKit
import HooksKit

final class SessionStatusHeuristicTests: XCTestCase {
    private let heuristic = SessionStatusHeuristic()

    func testDetectsCommonWaitingPhrases() {
        XCTAssertEqual(heuristic.detectStatus(in: "Do you want to proceed?"), .waitingForInput)
        XCTAssertEqual(heuristic.detectStatus(in: "Continue? (y/n)"), .waitingForInput)
        XCTAssertEqual(heuristic.detectStatus(in: "Permission required to write file"), .waitingForInput)
    }

    func testOrdinaryOutputDetectsNothing() {
        XCTAssertNil(heuristic.detectStatus(in: "Compiling module SessionKit..."))
        XCTAssertNil(heuristic.detectStatus(in: "Permission accepted; continuing"))
        XCTAssertNil(heuristic.detectStatus(in: ""))
    }
}

final class WaitingNotificationGateTests: XCTestCase {
    func testFiresOnlyOnTransitionIntoWaiting() {
        let gate = WaitingNotificationGate()
        XCTAssertTrue(gate.shouldNotify(for: .waitingForInput))
        XCTAssertFalse(gate.shouldNotify(for: .waitingForInput)) // still waiting, no repeat
        XCTAssertFalse(gate.shouldNotify(for: .working))
        XCTAssertTrue(gate.shouldNotify(for: .waitingForInput)) // waiting again after leaving
    }

    func testNeverFiresForNonWaitingStatuses() {
        let gate = WaitingNotificationGate()
        for status: SessionStatus in [.idle, .working, .finished, .crashed] {
            XCTAssertFalse(gate.shouldNotify(for: status))
        }
    }
}

final class SessionStatusObserverTests: XCTestCase {
    func testDetectsWaitingStatusFromMockOutput() async throws {
        let mock = MockPTYProcess()
        try mock.start(
            executable: URL(fileURLWithPath: "/bin/echo"),
            arguments: [],
            environment: [:],
            workingDirectory: URL(fileURLWithPath: "/tmp"),
            initialSize: PTYSize(cols: 80, rows: 24)
        )

        let observer = SessionStatusObserver(output: mock)
        observer.start()

        async let firstStatus = observer.statusStream.first(where: { _ in true })
        mock.simulateOutput("Proceed? (y/n) ")

        let status = await firstStatus
        XCTAssertEqual(status, .waitingForInput)
        observer.stop()
    }

    /// The permission-safety guarantee: SessionStatusObserver only ever
    /// holds a `SessionOutputObserving` reference (no send/terminate in
    /// that protocol's surface), so it structurally cannot call them even
    /// though the concrete mock instance backing it has those methods.
    /// This test proves the observer's behavior matches that guarantee —
    /// running a full scenario through it never once touches the mock's
    /// write-capable methods.
    func testObserverNeverExpandsProcessPermissions() async throws {
        let mock = MockPTYProcess()
        try mock.start(
            executable: URL(fileURLWithPath: "/bin/echo"),
            arguments: [],
            environment: [:],
            workingDirectory: URL(fileURLWithPath: "/tmp"),
            initialSize: PTYSize(cols: 80, rows: 24)
        )

        let observer = SessionStatusObserver(output: mock)
        observer.start()

        async let firstStatus = observer.statusStream.first(where: { _ in true })
        mock.simulateOutput("Do you want to continue? (y/n) ")
        _ = await firstStatus
        observer.stop()

        XCTAssertTrue(mock.sentInput.isEmpty, "observer must never call send(input:)")
        XCTAssertEqual(mock.terminateCallCount, 0, "observer must never call terminate()")
        XCTAssertTrue(mock.isRunning, "observer must never affect process lifecycle")
    }

    func testOrdinaryOutputTransitionsFromWorkingToIdleAfterQuietPeriod() async throws {
        let mock = MockPTYProcess()
        try mock.start(
            executable: URL(fileURLWithPath: "/bin/echo"),
            arguments: [],
            environment: [:],
            workingDirectory: URL(fileURLWithPath: "/tmp"),
            initialSize: PTYSize(cols: 80, rows: 24)
        )
        let observer = SessionStatusObserver(output: mock)
        observer.start()
        var iterator = observer.statusStream.makeAsyncIterator()

        mock.simulateOutput("Compiling workspace")

        let working = await iterator.next()
        let idle = await iterator.next()
        XCTAssertEqual(working, .working)
        XCTAssertEqual(idle, .idle)
        observer.stop()
    }

    func testWaitingPromptDoesNotDecayToIdleDuringQuietPeriod() async throws {
        let mock = MockPTYProcess()
        try mock.start(
            executable: URL(fileURLWithPath: "/bin/echo"),
            arguments: [],
            environment: [:],
            workingDirectory: URL(fileURLWithPath: "/tmp"),
            initialSize: PTYSize(cols: 80, rows: 24)
        )
        let observer = SessionStatusObserver(output: mock)
        observer.start()
        var iterator = observer.statusStream.makeAsyncIterator()

        mock.simulateOutput("Permission required (y/n)")
        let waiting = await iterator.next()
        XCTAssertEqual(waiting, .waitingForInput)
        try await Task.sleep(for: .milliseconds(2_200))

        mock.simulateOutput("Permission accepted")
        let resumed = await iterator.next()
        XCTAssertEqual(resumed, .working)
        observer.stop()
    }

    func testFragmentedPromptTailDoesNotUndoWaitingState() async throws {
        let mock = MockPTYProcess()
        try mock.start(
            executable: URL(fileURLWithPath: "/bin/echo"),
            arguments: [],
            environment: [:],
            workingDirectory: URL(fileURLWithPath: "/tmp"),
            initialSize: PTYSize(cols: 80, rows: 24)
        )
        let observer = SessionStatusObserver(output: mock)
        observer.start()
        var iterator = observer.statusStream.makeAsyncIterator()

        for fragment in ["Permission ", "required", " — awaiting choice"] {
            mock.simulateOutput(fragment)
        }
        var observed: SessionStatus?
        while observed != .waitingForInput {
            observed = await iterator.next()
        }
        XCTAssertEqual(observed, .waitingForInput)

        try await Task.sleep(for: .milliseconds(600))
        mock.simulateOutput("Compilation resumed")
        let resumed = await iterator.next()
        XCTAssertEqual(resumed, .working)
        observer.stop()
    }
}

final class NotificationDispatchingTests: XCTestCase {
    private final class RecordingDispatcher: NotificationDispatching, @unchecked Sendable {
        private(set) var notifiedTitles: [String] = []
        func notifyWaitingForInput(sessionTitle: String) async {
            notifiedTitles.append(sessionTitle)
        }
    }

    /// End-to-end wiring test: observer -> gate -> dispatcher, mirroring
    /// how the App-layer HookCoordinator composes these three pieces.
    func testFullPipelineNotifiesExactlyOnceForOneWaitingEpisode() async throws {
        let mock = MockPTYProcess()
        try mock.start(
            executable: URL(fileURLWithPath: "/bin/echo"),
            arguments: [],
            environment: [:],
            workingDirectory: URL(fileURLWithPath: "/tmp"),
            initialSize: PTYSize(cols: 80, rows: 24)
        )

        let observer = SessionStatusObserver(output: mock)
        let gate = WaitingNotificationGate()
        let dispatcher = RecordingDispatcher()

        let collectorTask = Task {
            for await status in observer.statusStream {
                if gate.shouldNotify(for: status) {
                    await dispatcher.notifyWaitingForInput(sessionTitle: "Test Session")
                }
            }
        }
        observer.start()

        mock.simulateOutput("Permission required (y/n) ")
        mock.simulateOutput("still waiting, permission required (y/n) ")
        try await Task.sleep(nanoseconds: 200_000_000)

        observer.stop()
        collectorTask.cancel()

        XCTAssertEqual(dispatcher.notifiedTitles, ["Test Session"])
    }
}

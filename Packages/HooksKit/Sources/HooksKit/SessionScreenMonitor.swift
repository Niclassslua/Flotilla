import Foundation
import SessionKit

/// Watches one session's screen and reports what it says the session is
/// doing. Polls rather than reacting to output, because the screen is a
/// level: re-reading it is always safe and always current, whereas an event
/// stream forces guesses about what each event meant.
///
/// Two cheap filters keep this quiet. An unchanged screen is not
/// reclassified at all, so a finished session costs one string comparison
/// per tick; and a classification identical to the last one is not emitted,
/// so an animating spinner produces exactly one `.working` for the whole
/// duration of the work.
public final class SessionScreenMonitor: @unchecked Sendable {
    private let sessionID: UUID
    private let reader: SessionScreenReading
    private let heuristic: TerminalScreenHeuristic
    private let pollInterval: Duration
    private let continuation: AsyncStream<SessionStatusObservation>.Continuation
    public let observationStream: AsyncStream<SessionStatusObservation>
    private let taskLock = NSLock()
    private var task: Task<Void, Never>?

    public init(
        sessionID: UUID,
        reader: SessionScreenReading,
        heuristic: TerminalScreenHeuristic = TerminalScreenHeuristic(),
        pollInterval: Duration = .milliseconds(900)
    ) {
        self.sessionID = sessionID
        self.reader = reader
        self.heuristic = heuristic
        self.pollInterval = pollInterval
        var continuation: AsyncStream<SessionStatusObservation>.Continuation!
        self.observationStream = AsyncStream { continuation = $0 }
        self.continuation = continuation
    }

    public func start() {
        taskLock.lock()
        defer { taskLock.unlock() }
        guard task == nil else { return }
        let sessionID = self.sessionID
        let reader = self.reader
        let heuristic = self.heuristic
        let pollInterval = self.pollInterval
        let continuation = self.continuation

        task = Task {
            var previousScreen: String?
            var previousObservation: SessionStatusObservation?

            while !Task.isCancelled {
                if let screen = await reader.readScreen(for: sessionID) {
                    // An unreadable screen leaves the status untouched: the
                    // renderer may simply not be mounted yet, which says
                    // nothing about what the agent is doing.
                    if screen != previousScreen {
                        previousScreen = screen
                        let observation = heuristic.observation(forScreen: screen)
                        if observation != previousObservation {
                            previousObservation = observation
                            continuation.yield(observation)
                        }
                    }
                }
                try? await Task.sleep(for: pollInterval)
            }
        }
    }

    public func stop() {
        taskLock.lock()
        let taskToCancel = task
        task = nil
        taskLock.unlock()
        taskToCancel?.cancel()
    }

    deinit {
        task?.cancel()
        continuation.finish()
    }
}

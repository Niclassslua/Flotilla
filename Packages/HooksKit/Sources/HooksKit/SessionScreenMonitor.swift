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
    private let continuation: AsyncStream<SessionStatus>.Continuation
    public let statusStream: AsyncStream<SessionStatus>
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
        var continuation: AsyncStream<SessionStatus>.Continuation!
        self.statusStream = AsyncStream { continuation = $0 }
        self.continuation = continuation
    }

    public func start() {
        guard task == nil else { return }
        let sessionID = self.sessionID
        let reader = self.reader
        let heuristic = self.heuristic
        let pollInterval = self.pollInterval
        let continuation = self.continuation

        task = Task {
            var previousScreen: String?
            var previousStatus: SessionStatus?

            while !Task.isCancelled {
                if let screen = await reader.readScreen(for: sessionID) {
                    // An unreadable screen leaves the status untouched: the
                    // renderer may simply not be mounted yet, which says
                    // nothing about what the agent is doing.
                    if screen != previousScreen {
                        previousScreen = screen
                        let status = heuristic.status(forScreen: screen)
                        if status != previousStatus {
                            previousStatus = status
                            continuation.yield(status)
                        }
                    }
                }
                try? await Task.sleep(for: pollInterval)
            }
        }
    }

    public func stop() {
        task?.cancel()
        task = nil
    }
}

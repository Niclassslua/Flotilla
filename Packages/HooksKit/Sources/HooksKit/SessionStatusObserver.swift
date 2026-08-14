import Foundation
import SessionKit
import ProcessKit

/// Watches a session's output and emits detected status changes. Takes
/// only `SessionOutputObserving` — never the full `PTYProcessProtocol` —
/// so this type has no `send`/`terminate`/`resize` available to it even by
/// accident; it is structurally incapable of controlling the process it
/// observes, only reading from it.
public final class SessionStatusObserver: @unchecked Sendable {
    private let output: SessionOutputObserving
    private let heuristic: SessionStatusHeuristic
    private let continuation: AsyncStream<SessionStatus>.Continuation
    public let statusStream: AsyncStream<SessionStatus>
    private var task: Task<Void, Never>?

    public init(output: SessionOutputObserving, heuristic: SessionStatusHeuristic = SessionStatusHeuristic()) {
        self.output = output
        self.heuristic = heuristic
        var continuation: AsyncStream<SessionStatus>.Continuation!
        self.statusStream = AsyncStream { continuation = $0 }
        self.continuation = continuation
    }

    /// Real terminal input/output often arrives one keystroke (or one PTY
    /// read) at a time — a prompt like "(y/n)" can land as several
    /// single-character chunks, none of which individually contain the
    /// pattern. So the heuristic runs against a rolling accumulated window
    /// of recent output, not each chunk in isolation.
    private static let windowSizeCharacters = 500

    public func start() {
        guard task == nil else { return }
        let stream = output.outputStream
        let heuristic = self.heuristic
        let continuation = self.continuation
        let windowSize = Self.windowSizeCharacters
        task = Task {
            var window = ""
            var idleTask: Task<Void, Never>?
            var mostRecentWaitingDetection: Date?
            for await chunk in stream {
                idleTask?.cancel()
                window += String(decoding: chunk, as: UTF8.self)
                if window.count > windowSize {
                    window = String(window.suffix(windowSize))
                }
                if let status = heuristic.detectStatus(in: window) {
                    continuation.yield(status)
                    mostRecentWaitingDetection = Date()
                    window = ""
                    // A permission/input prompt remains actionable until the
                    // process produces new output (normally after user input).
                    // Quiet time must not misclassify "waiting" as "idle".
                    continue
                }

                // A PTY often delivers the tail of the same prompt in a few
                // more tiny chunks after the first recognizable phrase. Do
                // not let those trailing characters immediately undo the
                // waiting state. Genuine response output arrives after the
                // user has had time to act and transitions back to working.
                if let mostRecentWaitingDetection,
                   Date().timeIntervalSince(mostRecentWaitingDetection) < 0.5 {
                    continue
                }
                mostRecentWaitingDetection = nil
                continuation.yield(.working)
                idleTask = Task {
                    try? await Task.sleep(for: .seconds(2))
                    guard !Task.isCancelled else { return }
                    continuation.yield(.idle)
                }
            }
            idleTask?.cancel()
        }
    }

    public func stop() {
        task?.cancel()
        task = nil
    }
}

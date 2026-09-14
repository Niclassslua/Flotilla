import Foundation
import SessionKit
import TranscriptKit

/// Everything session detail renders above the composer slot.
struct SessionTranscript: Sendable {
    /// The conversation plus phone-side notes, oldest first.
    var events: [TranscriptEvent] = []
    /// The in-progress assistant message at the provider's granularity.
    var streamingText: String?
    /// Antigravity only: the last lines of the Mac's terminal while a step runs.
    var terminalTail: String?
    /// Set while a provider retries (`Retrying · attempt 3`).
    var retryAttempt: Int?
    var isStopping = false
    var queuedPrompts: [QueuedPrompt] = []

    mutating func append(_ entry: CanonicalEntry) {
        events.append(TranscriptEvent(content: .entry(entry)))
    }

    mutating func append(_ content: TranscriptEvent.Content) {
        events.append(TranscriptEvent(content: content))
    }

    /// The latest *complete* line of assistant text — never the streaming
    /// partial — for the fleet row.
    var latestCompleteLine: String? {
        if let streamingText, let newline = streamingText.lastIndex(of: "\n") {
            let complete = streamingText[..<newline]
            if let line = complete.split(separator: "\n").last(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty }) {
                return String(line)
            }
        }
        for event in events.reversed() {
            if case .entry(.assistantMessage(let text, _)) = event.content {
                return text.split(separator: "\n").last(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty }).map(String.init)
            }
        }
        return nil
    }
}

struct TranscriptEvent: Identifiable, Sendable {
    enum Content: Sendable {
        case entry(CanonicalEntry)
        /// The compact trace a resolved card leaves (`Allowed Bash: npm test`).
        case resolvedInteraction(text: String, isPositive: Bool)
        case turnFailed(message: String)
    }

    let id = UUID()
    var content: Content
}

struct QueuedPrompt: Identifiable, Sendable {
    let id = UUID()
    var text: String
    var sentAt: Date
}

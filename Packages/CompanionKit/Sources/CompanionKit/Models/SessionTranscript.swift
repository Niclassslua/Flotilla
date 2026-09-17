import Foundation
import SessionKit
import TranscriptKit

/// Everything session detail renders above the composer slot.
public struct SessionTranscript: Hashable, Codable, Sendable {
    /// The conversation plus notes, oldest first.
    public var events: [TranscriptEvent]
    /// The in-progress assistant message at the provider's granularity.
    public var streamingText: String?
    /// Set while a provider retries (`Retrying · attempt 3`).
    public var retryAttempt: Int?
    public var isStopping: Bool
    /// Prompts sent while the agent was busy, not yet seen in the transcript.
    /// Tracked on the phone; the Mac always sends an empty list.
    public var queuedPrompts: [QueuedPrompt]
    /// Set when the Mac has no transcript for this session (OpenCode).
    public var unavailableReason: String?

    public init(
        events: [TranscriptEvent] = [],
        streamingText: String? = nil,
        retryAttempt: Int? = nil,
        isStopping: Bool = false,
        queuedPrompts: [QueuedPrompt] = [],
        unavailableReason: String? = nil
    ) {
        self.events = events
        self.streamingText = streamingText
        self.retryAttempt = retryAttempt
        self.isStopping = isStopping
        self.queuedPrompts = queuedPrompts
        self.unavailableReason = unavailableReason
    }

    public mutating func append(_ content: TranscriptEvent.Content) {
        events.append(TranscriptEvent(id: UUID().uuidString, content: content))
    }

    /// The latest *complete* line of assistant text — never the streaming
    /// partial — for the fleet row.
    public var latestCompleteLine: String? {
        func lastLine<S: StringProtocol>(_ text: S) -> String? {
            text.split(separator: "\n")
                .last { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
                .map { String($0) }
        }
        if let streamingText, let newline = streamingText.lastIndex(of: "\n"),
           let line = lastLine(streamingText[..<newline]) {
            return line
        }
        for event in events.reversed() {
            if case .assistantMessage(let text, _) = event.content {
                return lastLine(text)
            }
        }
        return nil
    }
}

/// A change relative to the last transcript delivered to this phone. Events
/// retained from the old window must match exactly; edits in older records
/// fall back to a new snapshot instead of silently corrupting the history.
public struct TranscriptDelta: Hashable, Codable, Sendable {
    public var baseRevision: UInt64
    public var revision: UInt64
    public var dropCount: Int
    public var retainCount: Int
    public var events: [TranscriptEvent]
    public var streamingText: String?
    public var retryAttempt: Int?
    public var isStopping: Bool
    public var unavailableReason: String?

    public static func make(from old: SessionTranscript, to new: SessionTranscript, baseRevision: UInt64) -> Self? {
        // A capped window may slide forward, and its last event may change
        // while it is being written. Keep only an equal overlapping prefix.
        let first = old.events.firstIndex { $0.id == new.events.first?.id } ?? old.events.count
        var retained = 0
        while first + retained < old.events.count, retained < new.events.count,
              old.events[first + retained] == new.events[retained] {
            retained += 1
        }
        guard retained > 0 || old.events.isEmpty || new.events.isEmpty else { return nil }
        return Self(
            baseRevision: baseRevision, revision: baseRevision + 1,
            dropCount: first, retainCount: retained,
            events: Array(new.events.dropFirst(retained)),
            streamingText: new.streamingText, retryAttempt: new.retryAttempt,
            isStopping: new.isStopping, unavailableReason: new.unavailableReason
        )
    }

    public func applying(to old: SessionTranscript, revision currentRevision: UInt64) -> SessionTranscript? {
        guard currentRevision == baseRevision, revision == baseRevision + 1,
              dropCount >= 0, retainCount >= 0,
              dropCount <= old.events.count,
              retainCount <= old.events.count - dropCount else { return nil }
        var result = old
        result.events = Array(old.events.dropFirst(dropCount).prefix(retainCount)) + events
        result.streamingText = streamingText
        result.retryAttempt = retryAttempt
        result.isStopping = isStopping
        result.unavailableReason = unavailableReason
        return result
    }
}

public struct TranscriptEvent: Identifiable, Hashable, Codable, Sendable {
    public enum Content: Hashable, Codable, Sendable {
        case userMessage(text: String, timestamp: Date)
        case assistantMessage(text: String, timestamp: Date)
        /// `input` holds the call's top-level scalar arguments as strings.
        case toolUse(id: String, tool: String, input: [String: String], timestamp: Date)
        case toolResult(toolUseID: String, output: String, isError: Bool, timestamp: Date)
        case systemNote(text: String, timestamp: Date)
        /// A screenshot the agent took and looked at — Codex's `view_image`,
        /// downsampled to a JPEG on the Mac before it travels. `filename` is
        /// the name the agent gave the file, when it sent one.
        case image(mimeType: String, base64: String, filename: String?, timestamp: Date)
        case handoff(from: AgentKind, to: AgentKind, timestamp: Date)
        /// The compact trace a resolved card leaves (`Allowed Bash: npm test`).
        case resolvedInteraction(text: String, isPositive: Bool)
        case turnFailed(message: String)
    }

    /// Stable across snapshots of the same transcript, so views keep identity.
    public let id: String
    public var content: Content

    public init(id: String, content: Content) {
        self.id = id
        self.content = content
    }
}

public struct QueuedPrompt: Identifiable, Hashable, Codable, Sendable {
    public let id: UUID
    public var text: String
    public var sentAt: Date

    public init(id: UUID = UUID(), text: String, sentAt: Date) {
        self.id = id
        self.text = text
        self.sentAt = sentAt
    }
}

extension TranscriptEvent.Content {
    /// Maps an agent-neutral transcript entry to its wire form.
    public init?(_ entry: CanonicalEntry) {
        switch entry {
        case .userMessage(let text, let timestamp):
            self = .userMessage(text: text, timestamp: timestamp)
        case .assistantMessage(let text, let timestamp):
            self = .assistantMessage(text: text, timestamp: timestamp)
        case .toolUse(let id, let tool, let input, let timestamp):
            self = .toolUse(id: id, tool: tool, input: Self.scalarArguments(input), timestamp: timestamp)
        case .toolResult(let toolUseID, let output, let isError, let timestamp):
            self = .toolResult(toolUseID: toolUseID, output: output, isError: isError, timestamp: timestamp)
        case .image(let mimeType, let base64, let filename, let timestamp):
            self = .image(mimeType: mimeType, base64: base64, filename: filename, timestamp: timestamp)
        case .handoffMarker(let from, let to, _, let timestamp):
            self = .handoff(from: from, to: to, timestamp: timestamp)
        case .systemNote(let text, let timestamp):
            self = .systemNote(text: text, timestamp: timestamp)
        }
    }

    /// Top-level string and number arguments of a tool call. Codex stores its
    /// arguments as a JSON *string* inside the JSON, so one level of string
    /// decoding is attempted too.
    public static func scalarArguments(_ data: Data) -> [String: String] {
        guard var object = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) else { return [:] }
        if let string = object as? String, let nested = string.data(using: .utf8),
           let decoded = try? JSONSerialization.jsonObject(with: nested) {
            object = decoded
        }
        guard let dictionary = object as? [String: Any] else { return [:] }
        return dictionary.compactMapValues { value in
            switch value {
            case let string as String: string
            case let number as NSNumber: number.stringValue
            case let array as [Any]:
                (try? JSONSerialization.data(withJSONObject: array)).flatMap { String(data: $0, encoding: .utf8) }
            default: nil
            }
        }
    }
}

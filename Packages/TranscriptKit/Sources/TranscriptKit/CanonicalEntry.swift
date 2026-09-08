import Foundation
import SessionKit

/// One entry of a conversation, in a form no agent owns.
///
/// Every coding agent stores its transcript in its own shape: Claude Code
/// writes a `parentUuid`-linked JSONL list under `~/.claude/projects`, Codex
/// writes flat `response_item` records into a date-nested rollout file. Moving
/// a session between them means translating between those shapes, and
/// translating *N* formats pairwise would need *N²* codecs. This type is the
/// hub — an agent only has to read *into* it and write *out of* it, and every
/// pair works.
///
/// Entries are ordered oldest-first. Each carries its own timestamp because
/// the two ends disagree about where time lives: Claude stamps every record,
/// Codex stamps the envelope around it.
///
/// This model is deliberately lossy. It carries what survives a move between
/// providers and nothing else — see ``CanonicalEntry/image(mimeType:base64:timestamp:)``
/// for a case that some targets drop, and note the absence of any reasoning
/// case at all: a provider's reasoning trace is bound to the turn that
/// produced it and cannot be replayed into another provider.
public enum CanonicalEntry: Sendable, Equatable {
    /// Something the human said.
    case userMessage(text: String, timestamp: Date)

    /// Something the agent said. Tool calls are separate entries, so a single
    /// agent turn that narrates and then acts becomes an `assistantMessage`
    /// followed by one or more `toolUse` entries.
    case assistantMessage(text: String, timestamp: Date)

    /// A tool invocation. `input` holds the arguments as raw JSON bytes rather
    /// than a decoded structure: the two ends disagree about the encoding
    /// (Claude nests an object, Codex stores a JSON *string*) and neither the
    /// hub nor any codec needs to understand what is inside.
    case toolUse(id: String, tool: String, input: Data, timestamp: Date)

    /// A tool's return value, tied back to ``CanonicalEntry/toolUse(id:tool:input:timestamp:)``
    /// by `toolUseID`. Providers enforce strict pairing between the two — see
    /// ``ToolCallPairing`` for why that is this module's problem and not the
    /// caller's.
    case toolResult(toolUseID: String, output: String, isError: Bool, timestamp: Date)

    /// An inline image. Not every target can represent one; a codec that
    /// cannot must drop it in `sanitize(_:)` rather than fail the move.
    case image(mimeType: String, base64: String, timestamp: Date)

    /// The seam itself, recorded in the conversation it describes.
    ///
    /// Its presence is also a signal to codecs: a transcript that contains a
    /// marker is being written for an agent that did not produce it, which for
    /// some targets means writing extra records so their UI can replay a
    /// history it never saw arrive.
    case handoffMarker(from: AgentKind, to: AgentKind, reason: String, timestamp: Date)

    /// Out-of-band text addressed to the reader rather than to either party —
    /// a notice, a local command's output.
    case systemNote(text: String, timestamp: Date)
}

extension CanonicalEntry {
    /// When this entry happened. Codecs order and stamp records by it.
    public var timestamp: Date {
        switch self {
        case let .userMessage(_, timestamp),
             let .assistantMessage(_, timestamp),
             let .toolUse(_, _, _, timestamp),
             let .toolResult(_, _, _, timestamp),
             let .image(_, _, timestamp),
             let .handoffMarker(_, _, _, timestamp),
             let .systemNote(_, timestamp):
            return timestamp
        }
    }

    /// Whether this entry is part of the conversation, as opposed to
    /// bookkeeping about it.
    ///
    /// A transcript of nothing but markers and notes has no history to move,
    /// which is a different situation from a transcript that failed to parse
    /// and must be reported differently — see ``TranscriptCodecError/emptySource``.
    public var isConversational: Bool {
        switch self {
        case .userMessage, .assistantMessage, .toolUse, .toolResult, .image:
            return true
        case .handoffMarker, .systemNote:
            return false
        }
    }
}

extension Array where Element == CanonicalEntry {
    /// True when there is an actual conversation here to hand over.
    public var hasConversationalContent: Bool {
        contains(where: \.isConversational)
    }

    /// Appends the seam. Callers record the move *before* handing the list to
    /// a target codec, so the marker is visible to `sanitize(_:)` and to any
    /// codec that changes what it writes when one is present.
    public func appendingHandoffMarker(
        from source: AgentKind,
        to target: AgentKind,
        reason: String = "user-requested",
        at timestamp: Date = Date()
    ) -> [CanonicalEntry] {
        self + [.handoffMarker(from: source, to: target, reason: reason, timestamp: timestamp)]
    }
}

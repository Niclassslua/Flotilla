import Foundation
import SessionKit

/// What a target codec hands back once it has written a transcript the target
/// agent will accept.
///
/// Deliberately not a `URL`. The three agents resume by three different
/// things — Claude by file path, Codex by the UUID embedded in the rollout's
/// filename, a server-backed agent by an id its API assigns — and flattening
/// that to a path would force every caller to know which kind it was holding.
/// `nativeSessionID` is what the launch layer needs; `transcriptURL` is what
/// the cleanup layer needs, and is `nil` for agents whose state is not a file.
public struct ResumeHandle: Sendable, Equatable {
    /// Goes straight into `Session.agentSessionID`, which the launch layer
    /// already turns into a resume argument.
    public let nativeSessionID: String

    /// Where the transcript landed, when it landed anywhere on disk.
    public let transcriptURL: URL?

    public init(nativeSessionID: String, transcriptURL: URL? = nil) {
        self.nativeSessionID = nativeSessionID
        self.transcriptURL = transcriptURL
    }
}

/// Reading an agent's native transcript into ``CanonicalEntry`` values.
///
/// Split from ``TranscriptWriting`` on purpose: an agent can be a handoff
/// *source* without being a *target*. Antigravity is the standing example —
/// its `transcript.jsonl` is readable, but its actual conversation state is
/// protobuf blobs in a per-conversation SQLite database with no published
/// schema, so it can be escaped from and not moved into. Conflating the two
/// halves into one protocol would force a `fatalError`-shaped hole into the
/// codecs that only do one of them, and would make "which agents can I move
/// this to?" a hardcoded list instead of a property of the type system.
public protocol TranscriptReading: Sendable {
    var agent: AgentKind { get }

    /// Where this agent keeps the transcript for a pinned native session id.
    ///
    /// Returns `nil` when no such transcript exists. Implementations must
    /// derive the location from `sessionID` and `workingDirectory` — never by
    /// picking the most recently modified file in a directory. Sessions share
    /// working directories (several can run against one worktree), so recency
    /// silently resolves to another session's conversation.
    func transcriptURL(sessionID: String, workingDirectory: URL) throws -> URL?

    /// The session id this file claims to belong to, or `nil` when the format
    /// does not record one.
    ///
    /// Used to verify ownership before a move consumes and deletes a file. A
    /// mismatch means the path resolved to a conversation we do not own.
    func embeddedSessionID(at url: URL) throws -> String?

    /// Parses the transcript. Unknown record types are skipped rather than
    /// treated as errors — these formats are undocumented and gain fields
    /// between releases, so a strict parser would break on every upstream
    /// version bump.
    func readNative(at url: URL) throws -> [CanonicalEntry]
}

/// Writing ``CanonicalEntry`` values into an agent's native transcript format,
/// such that the agent will resume from it as if it were its own.
public protocol TranscriptWriting: Sendable {
    var agent: AgentKind { get }

    /// Drops what this agent cannot represent, and repairs what it requires.
    ///
    /// Must never throw. A target that cannot carry an image drops the image;
    /// it does not fail the move. Callers apply this immediately before
    /// ``writeNative(_:workingDirectory:sessionID:)``.
    func sanitize(_ entries: [CanonicalEntry]) -> [CanonicalEntry]

    /// Writes a transcript the target will accept, and returns what is needed
    /// to resume it.
    ///
    /// `sessionID` is the identity the transcript must claim. Passing it in
    /// rather than minting one inside the codec is what lets the caller pin a
    /// move to a known id and verify it afterwards.
    func writeNative(
        _ entries: [CanonicalEntry],
        workingDirectory: URL,
        sessionID: String
    ) throws -> ResumeHandle

    /// Removes this agent's state for a session that has moved elsewhere.
    ///
    /// Called only after the destination is known to be healthy. Agents keep
    /// more than a transcript — todo lists, debug logs, per-session
    /// environment directories — and leaving those behind lets an agent
    /// believe it still owns a conversation that has moved on.
    ///
    /// Best-effort by contract: a missing sidecar is not an error.
    func removeNativeState(sessionID: String, workingDirectory: URL) throws
}

/// Failures that are worth telling the user apart.
public enum TranscriptCodecError: LocalizedError, Equatable {
    /// The transcript exists but holds no conversation to move.
    case emptySource(URL)
    /// The file claims to belong to a different session than the one we hold.
    case foreignSource(url: URL, embedded: String, expected: String)
    /// The transcript could not be parsed as this agent's format at all.
    case malformed(url: URL, detail: String)
    /// A required identifier was not in the shape the target demands.
    case invalidSessionID(String)

    public var errorDescription: String? {
        switch self {
        case let .emptySource(url):
            return "The transcript at \(url.lastPathComponent) has no conversation to hand over."
        case let .foreignSource(url, embedded, expected):
            return "\(url.lastPathComponent) belongs to session \(embedded), not \(expected)."
        case let .malformed(url, detail):
            return "Could not read \(url.lastPathComponent): \(detail)"
        case let .invalidSessionID(id):
            return "\(id) is not a valid session identifier for this agent."
        }
    }
}

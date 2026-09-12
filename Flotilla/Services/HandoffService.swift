import Foundation
import SessionKit
import TranscriptKit

/// Moves a running session from one coding agent to another without losing the
/// conversation.
///
/// The mechanism is a transcode, not a summary: the current agent's transcript
/// is read into `CanonicalEntry` values and re-emitted in the destination's own
/// format, so the destination resumes what it takes to be its own prior
/// session. No model is involved.
///
/// **Move, not copy.** Exactly one agent owns a conversation at a time. Leaving
/// both transcripts in place would let two agents append to the same history
/// and silently fork it.
///
/// **The source outlives the switch.** `perform` writes the destination and
/// relaunches, but leaves the source transcript on disk and records a
/// ``PendingHandoff``. Only once the destination has proved it can run does
/// ``finalize(_:)`` delete the source. A destination that dies immediately —
/// a missing binary, an expired login — is put back by ``rollback(_:)`` onto a
/// transcript that was never destroyed. Deleting at the moment of the move
/// would make that failure unrecoverable.
///
/// The type performs no persistence and holds no timers: it returns the updated
/// `Session` and lets `AppStore` save it, the same shape `restartSession` uses.
@MainActor
final class HandoffService {
    /// What a move would do, computed without doing it. Safe to call for menu
    /// enablement and for a confirmation step.
    struct Plan: Equatable {
        let session: Session
        let target: AgentKind
        /// The source agent's own id. Resolved during planning, because for an
        /// agent that mints its own it may not be on the session yet.
        let sourceSessionID: String
        let sourceTranscript: URL
        let entries: [CanonicalEntry]
        /// Tool calls that never returned and were given a placeholder result.
        let synthesizedToolResults: Int
        /// Results whose call is missing from the transcript, dropped.
        let droppedOrphanResults: Int

        var entryCount: Int { entries.count }
    }

    enum HandoffError: LocalizedError, Equatable {
        case sourceNotReadable(AgentKind)
        case targetNotWritable(AgentKind)
        case noNativeSession
        case sourceNotFound(AgentKind)
        case foreignSource(url: URL, embedded: String, expected: String)
        case emptySource
        case targetFailedToStart(String)

        var errorDescription: String? {
            switch self {
            case let .sourceNotReadable(agent):
                return "\(agent.displayName) sessions cannot be handed off yet."
            case let .targetNotWritable(agent):
                return "A session cannot be handed off to \(agent.displayName)."
            case .noNativeSession:
                return "This session has not started a conversation yet."
            case let .sourceNotFound(agent):
                return "\(agent.displayName)'s transcript for this session could not be found."
            case let .foreignSource(url, embedded, expected):
                return "\(url.lastPathComponent) belongs to session \(embedded), not \(expected)."
            case .emptySource:
                return "There is no conversation here to hand over."
            case let .targetFailedToStart(message):
                return "The destination agent did not start: \(message)"
            }
        }
    }

    private let processManager: any SessionProcessStarting
    private let registry: TranscriptCodecRegistry
    private let now: () -> Date

    /// How long a destination has to stay alive before the move is considered
    /// settled. An agent that is going to fail on a missing binary or a bad
    /// login does so immediately; one still running after this has read the
    /// transcript and started work.
    let probationWindow: Duration

    init(
        processManager: any SessionProcessStarting,
        registry: TranscriptCodecRegistry = .flotilla(),
        probationWindow: Duration = .seconds(6),
        now: @escaping () -> Date = { Date() }
    ) {
        self.processManager = processManager
        self.registry = registry
        self.probationWindow = probationWindow
        self.now = now
    }

    // MARK: - Eligibility

    /// The agents this session can be moved to, derived from which codecs
    /// exist rather than from a list anyone has to remember to update.
    func targets(for session: Session) -> [AgentKind] {
        registry.handoffTargets(from: session.agent)
    }

    func canHandOff(_ session: Session) -> Bool {
        !targets(for: session).isEmpty && session.pendingHandoff == nil
    }

    // MARK: - Planning

    func plan(for session: Session, to target: AgentKind) throws -> Plan {
        guard let reader = registry.reader(for: session.agent) else {
            throw HandoffError.sourceNotReadable(session.agent)
        }
        guard registry.writer(for: target) != nil else {
            throw HandoffError.targetNotWritable(target)
        }
        // An agent that mints its own id may not have had it pinned yet — the
        // background monitor polls, and leans on the agent's own catalog, which
        // can lag the conversation or omit it until the agent has titled it.
        // Asking the codec directly is what stops a live session being refused
        // as "not started".
        let nativeID: String
        let source: URL
        if let recorded = session.agentSessionID, !recorded.isEmpty {
            nativeID = recorded

            // Prefer the recorded path. Rediscovery by working directory is a
            // fallback only: sessions share directories, and `workingDirectory`
            // can be rewritten after launch for an agent-managed worktree, so
            // it is not a reliable way to find *this* conversation.
            if let path = session.nativeTranscriptPath,
               FileManager.default.fileExists(atPath: path.path) {
                source = path
            } else if let found = try reader.transcriptURL(
                sessionID: nativeID,
                workingDirectory: session.workingDirectory
            ) {
                source = found
            } else {
                throw HandoffError.sourceNotFound(session.agent)
            }
        } else if let discovered = try reader.discoverSession(
            workingDirectory: session.workingDirectory,
            // A small grace before launch: the agent may create its transcript
            // fractionally before the process is recorded as started.
            since: session.createdAt.addingTimeInterval(-30)
        ) {
            nativeID = discovered.sessionID
            source = discovered.url
        } else {
            throw HandoffError.noNativeSession
        }

        // Consuming a transcript deletes it, so prove it is ours first.
        if let embedded = try reader.embeddedSessionID(at: source),
           embedded.caseInsensitiveCompare(nativeID) != .orderedSame {
            throw HandoffError.foreignSource(url: source, embedded: embedded, expected: nativeID)
        }

        let read = try reader.readNative(at: source)
        guard read.hasConversationalContent else { throw HandoffError.emptySource }

        let marked = read.appendingHandoffMarker(from: session.agent, to: target, at: now())
        let paired = ToolCallPairing.pair(marked)

        return Plan(
            session: session,
            target: target,
            sourceSessionID: nativeID,
            sourceTranscript: source,
            entries: paired.entries,
            synthesizedToolResults: paired.synthesizedResults,
            droppedOrphanResults: paired.droppedOrphanResults
        )
    }

    // MARK: - The move

    /// Writes the destination transcript, stops the source agent and starts the
    /// destination. Returns the session to persist; the caller owns saving it.
    ///
    /// The returned session carries a ``PendingHandoff`` and is not settled
    /// until ``finalize(_:)`` or ``rollback(_:)`` runs.
    func perform(_ plan: Plan) async throws -> Session {
        guard let writer = registry.writer(for: plan.target) else {
            throw HandoffError.targetNotWritable(plan.target)
        }
        let session = plan.session
        let sourceSessionID = plan.sourceSessionID

        // Quiesce and kill existing source process before writing destination state
        processManager.terminate(sessionID: session.id)
        processManager.killServerSideSession(sessionID: session.id)

        // A fresh identity per move. Reusing one risks colliding with a
        // transcript the destination already has, and Codex refuses to resume
        // a thread another process is holding open.
        let targetSessionID = UUID().uuidString.lowercased()
        let handle = try await writer.writeNative(
            writer.sanitize(plan.entries),
            workingDirectory: session.workingDirectory,
            sessionID: targetSessionID
        )

        // Both, in this order. A surviving tmux session makes the relaunch
        // reattach to the *old* agent instead of starting the new one, with no
        // error to show for it.
        processManager.terminate(sessionID: session.id)
        processManager.killServerSideSession(sessionID: session.id)

        var moved = session
        moved.agent = plan.target
        moved.agentSessionID = handle.nativeSessionID
        moved.nativeTranscriptPath = handle.transcriptURL

        // A model and an effort level belong to the agent that was running, not
        // to the session. `opusplan` means nothing to Codex and `gpt-6-astra`
        // means nothing to Claude; carrying either across makes the destination
        // refuse to start on a model it has never heard of. Effort is the same
        // shape of problem — `.minimal` and `.ultra` are Codex-only, `.max` is
        // not universal — so both reset to the destination's own default and
        // are remembered for a rollback.
        moved.model = nil
        moved.effort = nil
        moved.pendingHandoff = PendingHandoff(
            sourceAgent: session.agent,
            sourceSessionID: sourceSessionID,
            sourceTranscriptPath: plan.sourceTranscript,
            sourceModel: session.model,
            sourceEffort: session.effort,
            startedAt: now()
        )

        do {
            try processManager.startSession(moved, deliverGoal: false)
        } catch {
            // Nothing has been deleted, so the session can simply go back.
            _ = try? await rollback(moved)
            throw HandoffError.targetFailedToStart(error.localizedDescription)
        }

        return moved
    }

    /// The destination survived probation. Releases the source agent's claim on
    /// the conversation and clears the probation record.
    ///
    /// Cleanup is best-effort by design: a leftover sidecar is untidy, a failed
    /// handoff is not, and this runs after the move has already succeeded.
    func finalize(_ session: Session) -> Session {
        guard let pending = session.pendingHandoff else { return session }

        if let reader = registry.writer(for: pending.sourceAgent) {
            try? reader.removeNativeState(
                sessionID: pending.sourceSessionID,
                workingDirectory: session.workingDirectory
            )
        }
        try? FileManager.default.removeItem(at: pending.sourceTranscriptPath)

        var settled = session
        settled.pendingHandoff = nil
        return settled
    }

    /// The destination never got going. Puts the session back on the agent it
    /// came from, which still has its transcript because nothing was deleted.
    func rollback(_ session: Session) async throws -> Session {
        guard let pending = session.pendingHandoff else { return session }

        // Discard the destination transcript we wrote; it is unreferenced now.
        if let writer = registry.writer(for: session.agent),
           let targetSessionID = session.agentSessionID {
            try? writer.removeNativeState(
                sessionID: targetSessionID,
                workingDirectory: session.workingDirectory
            )
        }

        var restored = session
        restored.agent = pending.sourceAgent
        restored.agentSessionID = pending.sourceSessionID
        restored.nativeTranscriptPath = pending.sourceTranscriptPath
        restored.model = pending.sourceModel
        restored.effort = pending.sourceEffort
        restored.pendingHandoff = nil

        processManager.terminate(sessionID: session.id)
        processManager.killServerSideSession(sessionID: session.id)
        try processManager.startSession(restored, deliverGoal: false)

        return restored
    }
}

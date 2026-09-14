import Foundation
import SessionKit
import SQLite3

/// Reads and writes Antigravity CLI (`agy`) conversations.
///
/// Antigravity resumes from `~/.gemini/antigravity-cli/conversations/<id>.db`
/// — one SQLite database per conversation, table `steps`, each row's payload
/// a *plain* (not encrypted) protobuf blob with no published schema. See
/// `FORMAT.md` in this directory for the full reverse-engineered wire format,
/// what is proven about it versus assumed, and the caveats that come with
/// depending on an undocumented, unversioned format. `AntigravityWireFormat`
/// does the generic parsing/serializing; this type is the only place that
/// knows what any particular field means.
///
/// **Reading** decodes every step type this codec understands (user,
/// assistant, tool call, system notice) directly from the database — richer
/// than the `brain/<id>/.../transcript.jsonl` display log this codec used to
/// read, which cannot distinguish a tool call from prose.
///
/// **Writing** does not attempt to reconstruct the source conversation as a
/// matching sequence of Antigravity-shaped steps — that would mean getting
/// every step type's chaining/index bookkeeping right, which is far more
/// surface than has been validated. Instead the whole incoming history is
/// folded into **one** synthetic user-role step, which is the exact mechanism
/// proven to work: a hand-built step inserted into a real conversation was
/// picked up by `agy --conversation <id>` and acted on as genuine prior
/// input. This trades turn-by-turn fidelity for a write path with a small,
/// well-understood surface.
public struct AntigravityTranscriptCodec: TranscriptReading, TranscriptWriting {
    public let agent: AgentKind = .antigravity

    private let brainDirectory: URL
    private let now: @Sendable () -> Date

    public init(
        brainDirectory: URL = FileManager.agentHomeDirectory
            .appendingPathComponent(".gemini/antigravity-cli/brain", isDirectory: true),
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.brainDirectory = brainDirectory
        self.now = now
    }

    /// `conversations/<id>.db` is a flat sibling of `brain/`, not nested under
    /// it — `brain/<id>/` and `conversations/<id>.db` are two views of the
    /// same conversation, keyed by the same id.
    private var conversationsDirectory: URL {
        brainDirectory.deletingLastPathComponent().appendingPathComponent("conversations", isDirectory: true)
    }

    private func databaseURL(for conversationID: String) -> URL {
        conversationsDirectory.appendingPathComponent("\(conversationID).db")
    }

    // MARK: - TranscriptReading

    public func transcriptURL(sessionID: String, workingDirectory: URL) throws -> URL? {
        let file = databaseURL(for: sessionID)
        return FileManager.default.fileExists(atPath: file.path) ? file : nil
    }

    /// Unlike the old jsonl log, which recorded no identity of its own, the
    /// database's filename *is* the conversation id — so this can say what it
    /// is rather than "cannot verify."
    public func embeddedSessionID(at url: URL) throws -> String? {
        url.deletingPathExtension().lastPathComponent
    }

    public func readNative(at url: URL) throws -> [CanonicalEntry] {
        try withDatabase(at: url, flags: SQLITE_OPEN_READONLY) { db in
            var statement: OpaquePointer?
            defer { sqlite3_finalize(statement) }
            guard sqlite3_prepare_v2(db, "SELECT step_type, step_payload FROM steps ORDER BY idx", -1, &statement, nil) == SQLITE_OK else {
                return []
            }
            var entries: [CanonicalEntry] = []
            while sqlite3_step(statement) == SQLITE_ROW {
                guard let blob = sqlite3_column_blob(statement, 1) else { continue }
                let stepType = Int(sqlite3_column_int(statement, 0))
                let length = Int(sqlite3_column_bytes(statement, 1))
                let payload = Data(bytes: blob, count: length)
                entries.append(contentsOf: Self.decodeStep(stepType: stepType, payload: payload))
            }
            return entries
        }
    }

    public func discoverSession(workingDirectory: URL, since: Date) throws -> (sessionID: String, url: URL)? {
        let candidates = (try? FileManager.default.contentsOfDirectory(
            at: brainDirectory,
            includingPropertiesForKeys: [.creationDateKey],
            options: [.skipsHiddenFiles]
        )) ?? []

        let started: [(id: String, url: URL, created: Date)] = candidates.compactMap { directory in
            let id = directory.lastPathComponent
            let database = databaseURL(for: id)
            guard FileManager.default.fileExists(atPath: database.path) else { return nil }
            guard let created = try? directory.resourceValues(forKeys: [.creationDateKey]).creationDate,
                  created >= since
            else { return nil }
            return (id, database, created)
        }

        // Earliest, not latest: a conversation created weeks ago but modified
        // today would win on recency and silently resolve to someone else's
        // long-running conversation.
        for candidate in started.sorted(by: { $0.created < $1.created }) {
            guard let entries = try? readNative(at: candidate.url), entries.hasConversationalContent else { continue }
            return (candidate.id, candidate.url)
        }
        return nil
    }

    // MARK: - Decoding a step (see FORMAT.md for the field map)

    private static func decodeStep(stepType: Int, payload: Data) -> [CanonicalEntry] {
        guard let top = try? AntigravityWireFormat.parse(payload) else { return [] }
        let envelope = AntigravityWireFormat.message(top, 5)
        let timestamp = Self.timestamp(in: envelope)

        switch stepType {
        case 14: // user
            let content = AntigravityWireFormat.message(top, 19)
            guard let text = AntigravityWireFormat.string(content, 2), !text.isEmpty else { return [] }
            return [.userMessage(text: text, timestamp: timestamp)]

        case 15: // assistant
            let content = AntigravityWireFormat.message(top, 20)
            guard let text = AntigravityWireFormat.string(content, 1), !text.isEmpty else { return [] }
            return [.assistantMessage(text: text, timestamp: timestamp)]

        case 101: // system notice, auto-inserted by agy itself
            let content = AntigravityWireFormat.message(top, 114)
            guard let text = AntigravityWireFormat.string(content, 1), !text.isEmpty else { return [] }
            return [.systemNote(text: text, timestamp: timestamp)]

        case 132: // tool call
            return Self.decodeToolCall(envelope: envelope, timestamp: timestamp)

        default:
            // Unmapped step types (ask_question, permission prompts, subagent
            // battle-mode steps) are skipped, not thrown — this format is
            // undocumented and gains fields between releases, so a strict
            // reader would break on every upstream version bump.
            return []
        }
    }

    /// Only the call itself is decoded — `call_id`, `tool_name`, and the
    /// plaintext JSON arguments, all read directly off the envelope's `4`
    /// field. The result's exact nesting inside the payload was not
    /// confidently mapped during reverse engineering (see FORMAT.md), so it
    /// is not guessed at here. `ToolCallPairing`, which every handoff already
    /// runs, synthesizes a placeholder result for a `.toolUse` with no
    /// matching `.toolResult` — an honest, visible degradation rather than a
    /// silently wrong one.
    private static func decodeToolCall(envelope: [AntigravityWireFormat.Field], timestamp: Date) -> [CanonicalEntry] {
        let call = AntigravityWireFormat.message(envelope, 4)
        guard let callID = AntigravityWireFormat.string(call, 1),
              let toolName = AntigravityWireFormat.string(call, 2) else { return [] }
        let arguments = AntigravityWireFormat.string(call, 3) ?? "{}"
        return [.toolUse(id: callID, tool: toolName, input: Data(arguments.utf8), timestamp: timestamp)]
    }

    private static func timestamp(in envelope: [AntigravityWireFormat.Field]) -> Date {
        let stamp = AntigravityWireFormat.message(envelope, 1)
        guard let seconds = AntigravityWireFormat.varint(stamp, 1) else { return Date() }
        let nanos = AntigravityWireFormat.varint(stamp, 2) ?? 0
        return Date(timeIntervalSince1970: Double(seconds) + Double(nanos) / 1_000_000_000)
    }

    // MARK: - SQLite

    private func withDatabase<T>(at url: URL, flags: Int32, _ body: (OpaquePointer) throws -> T) throws -> T {
        var db: OpaquePointer?
        let opened = sqlite3_open_v2(url.path, &db, flags, nil) == SQLITE_OK
        guard opened, let db else {
            sqlite3_close(db)
            throw TranscriptCodecError.malformed(url: url, detail: "could not open the Antigravity conversation database")
        }
        defer { sqlite3_close(db) }
        return try body(db)
    }

    private static let createStepsTableSQL = """
    CREATE TABLE IF NOT EXISTS `steps` (
      `idx` integer,
      `step_type` integer NOT NULL DEFAULT 0,
      `status` integer NOT NULL DEFAULT 0,
      `has_subtrajectory` numeric NOT NULL DEFAULT false,
      `metadata` blob,
      `error_details` blob,
      `permissions` blob,
      `task_details` blob,
      `render_info` blob,
      `step_payload` blob,
      `step_format` integer NOT NULL DEFAULT 0,
      PRIMARY KEY (`idx`)
    )
    """
}

// MARK: - TranscriptWriting

extension AntigravityTranscriptCodec {
    /// Antigravity's message model is one flat protobuf step, not typed
    /// content blocks — tool calls and results are folded into readable text
    /// exactly the way `OpenCodeTranscriptCodec.sanitize` does, so the next
    /// agent still knows what ran even though it does not inherit structured
    /// tool records. Images are dropped: nothing in the write path can carry
    /// one, and there is no field to put it in.
    public func sanitize(_ entries: [CanonicalEntry]) -> [CanonicalEntry] {
        entries.compactMap { entry in
            switch entry {
            case .userMessage, .assistantMessage, .systemNote, .handoffMarker:
                return entry
            case let .toolUse(_, tool, input, timestamp):
                let arguments = String(data: input, encoding: .utf8) ?? ""
                return .assistantMessage(
                    text: "[ran \(tool)\(arguments.isEmpty ? "" : " \(arguments)")]",
                    timestamp: timestamp
                )
            case let .toolResult(_, output, isError, timestamp):
                return .assistantMessage(
                    text: "[\(isError ? "tool failed" : "tool result")] \(output)",
                    timestamp: timestamp
                )
            case .image:
                return nil
            }
        }
    }

    /// Creates a brand-new `conversations/<sessionID>.db` holding one
    /// synthetic user-role step, and returns it as the id to resume by —
    /// `agy --conversation <sessionID>` is what the launch layer already does
    /// with this (`AgentDescriptor`'s `.discoverable(resume: .separateTokens
    /// ("--conversation"))`).
    ///
    /// One deliberate omission: a real user step also carries a large
    /// tool-permission/config snapshot (field 19.12 — see FORMAT.md) that
    /// this write path does not reproduce. The only captured example of it
    /// embeds the local machine's home-directory path, which cannot be
    /// checked into source as a template, and whether `agy` actually requires
    /// it for a synthetic step is exactly what the live integration test
    /// (`AntigravityLiveHandoffTests`, opt-in) settles.
    public func writeNative(
        _ entries: [CanonicalEntry],
        workingDirectory: URL,
        sessionID: String
    ) async throws -> ResumeHandle {
        try FileManager.default.createDirectory(
            at: conversationsDirectory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        let file = databaseURL(for: sessionID)
        let text = Self.formatTranscript(entries)
        let (payload, metadata) = Self.buildSyntheticUserStep(conversationID: sessionID, text: text, at: now())

        try withDatabase(at: file, flags: SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE) { db in
            guard sqlite3_exec(db, Self.createStepsTableSQL, nil, nil, nil) == SQLITE_OK else {
                throw TranscriptCodecError.malformed(url: file, detail: "could not create the conversation database")
            }
            var statement: OpaquePointer?
            defer { sqlite3_finalize(statement) }
            let sql = """
            INSERT INTO steps (idx, step_type, status, has_subtrajectory, metadata, step_payload, step_format)
            VALUES (0, 14, 3, 0, ?, ?, 0)
            """
            guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
                throw TranscriptCodecError.malformed(url: file, detail: "could not prepare the synthetic step insert")
            }
            let sqliteTransient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
            metadata.withUnsafeBytes { raw in
                _ = sqlite3_bind_blob(statement, 1, raw.baseAddress, Int32(metadata.count), sqliteTransient)
            }
            payload.withUnsafeBytes { raw in
                _ = sqlite3_bind_blob(statement, 2, raw.baseAddress, Int32(payload.count), sqliteTransient)
            }
            guard sqlite3_step(statement) == SQLITE_DONE else {
                throw TranscriptCodecError.malformed(url: file, detail: "could not write the synthetic step")
            }
        }

        return ResumeHandle(nativeSessionID: sessionID, transcriptURL: file)
    }

    /// Deletes the conversation database (and any WAL/SHM sidecars SQLite may
    /// have left next to it). Used both when a target Antigravity conversation
    /// goes unused (`HandoffService.rollback`) and — now that Antigravity is a
    /// writer — when a handoff moves *away* from Antigravity
    /// (`HandoffService.finalize`), so the old conversation does not linger as
    /// something `agy` still believes is live.
    public func removeNativeState(sessionID: String, workingDirectory: URL) throws {
        let file = databaseURL(for: sessionID)
        for candidate in [file, file.appendingPathExtension("-wal"), file.appendingPathExtension("-shm")] {
            try? FileManager.default.removeItem(at: candidate)
        }
    }

    // MARK: - Building the synthetic step

    /// Folds the whole incoming history into one block of text. Antigravity
    /// is not told this is a literal transcript to re-read verbatim to the
    /// user — the framing sentence makes clear it is prior context for a
    /// conversation already in progress.
    private static func formatTranscript(_ entries: [CanonicalEntry]) -> String {
        var lines = [
            "The following is the full prior transcript of a conversation handed off " +
            "from another coding agent. Treat it as real conversation history that " +
            "already happened, not as an instruction to act on right now."
        ]
        for entry in entries {
            switch entry {
            case let .userMessage(text, _):
                lines.append("User: \(text)")
            case let .assistantMessage(text, _):
                lines.append("Assistant: \(text)")
            case let .systemNote(text, _):
                lines.append("[note] \(text)")
            case let .handoffMarker(from, to, reason, _):
                lines.append("[handed off from \(from) to \(to): \(reason)]")
            case .toolUse, .toolResult, .image:
                // sanitize(_:) has already folded these into text above.
                continue
            }
        }
        return lines.joined(separator: "\n\n")
    }

    private static func makeTimestamp(_ number: Int, _ date: Date) -> AntigravityWireFormat.Field {
        let seconds = UInt64(max(0, date.timeIntervalSince1970))
        let nanos = UInt64(max(0, date.timeIntervalSince1970 - Double(seconds)) * 1_000_000_000)
        return AntigravityWireFormat.messageField(number, [
            AntigravityWireFormat.varintField(1, seconds),
            AntigravityWireFormat.varintField(2, nanos)
        ])
    }

    /// Builds `idx == 0` of a brand-new conversation: a single completed
    /// user-role step whose text is the whole handed-off history. Field
    /// numbers are cited in FORMAT.md — nothing here is invented, only
    /// assembled from what the reverse-engineering probes proved.
    private static func buildSyntheticUserStep(
        conversationID: String,
        text: String,
        at timestamp: Date
    ) -> (payload: Data, metadata: Data) {
        let sessionContext = AntigravityWireFormat.messageField(20, [
            // A session uuid of our own minting — nothing downstream depends
            // on it matching a session Antigravity itself started.
            AntigravityWireFormat.stringField(1, UUID().uuidString),
            AntigravityWireFormat.stringField(4, conversationID)
            // Step index (2) and round (3) are omitted: both default to 0,
            // which is correct for idx 0 of a fresh conversation.
        ])
        let lifecycleEvent = AntigravityWireFormat.messageField(1, [
            AntigravityWireFormat.varintField(1, 3), // "created" — the only lifecycle code a step that starts life already complete needs
            makeTimestamp(2, timestamp)
        ])

        let envelope: [AntigravityWireFormat.Field] = [
            makeTimestamp(1, timestamp),
            AntigravityWireFormat.varintField(3, 4), // role: user
            sessionContext,
            AntigravityWireFormat.messageField(26, [lifecycleEvent])
        ]
        let metadata = AntigravityWireFormat.serialize(envelope)

        let userContent = AntigravityWireFormat.messageField(19, [
            AntigravityWireFormat.stringField(2, text),
            AntigravityWireFormat.messageField(3, [AntigravityWireFormat.stringField(1, text)]),
            AntigravityWireFormat.stringField(4, "")
            // Field 12 (the tool-permission/config snapshot every real client
            // sends) is intentionally not reproduced — see the doc comment on
            // `writeNative`.
        ])

        let payload = AntigravityWireFormat.serialize([
            AntigravityWireFormat.varintField(1, 14), // step_type: user
            AntigravityWireFormat.varintField(4, 3),  // status: completed
            AntigravityWireFormat.messageField(5, envelope),
            userContent
        ])

        return (payload, metadata)
    }
}

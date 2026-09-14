import Foundation
import SessionKit

/// Writes a session into OpenCode through its own `opencode import` command.
///
/// **Destination only.** OpenCode keeps conversations in a SQLite database
/// (`session` / `message` / `part`) held open by a running server, so there is
/// no transcript file to read or delete. Its CLI offers `export` and `import`
/// but no way to *remove* a session — which means a move *out of* OpenCode
/// could not relinquish OpenCode's copy, and two agents would end up believing
/// they own the same conversation. Rather than write into a live server's
/// database behind its back, this codec only ever adds.
///
/// This is why ``TranscriptReading`` and ``TranscriptWriting`` are separate
/// protocols: this codec is a target and never a source. (``AntigravityTranscriptCodec``
/// used to be the mirror image — source-only — until its write path was
/// reverse-engineered too; see `FORMAT.md` alongside it.)
public struct OpenCodeTranscriptCodec: TranscriptWriting {
    public let agent: AgentKind = .openCode

    /// Hands a prepared export file to `opencode import`.
    ///
    /// Injected rather than executed here so this stays a pure encoder with no
    /// subprocess dependency: the app supplies a runner, tests supply a
    /// recorder. It also means the transcript is written by OpenCode itself
    /// through a supported interface, not by us reaching into its database.
    public typealias SessionImporting = @Sendable (URL) async throws -> Void

    private let stagingDirectory: URL
    private let importSession: SessionImporting
    private let providerID: String
    private let modelID: String
    private let agentMode: String
    private let openCodeVersion: String
    private let now: @Sendable () -> Date

    public init(
        stagingDirectory: URL = FileManager.default.temporaryDirectory
            .appendingPathComponent("flotilla-opencode-import", isDirectory: true),
        providerID: String = "opencode",
        modelID: String = "big-pickle",
        agentMode: String = "build",
        openCodeVersion: String = "1.18.25",
        now: @escaping @Sendable () -> Date = { Date() },
        importSession: @escaping SessionImporting
    ) {
        self.stagingDirectory = stagingDirectory
        self.providerID = providerID
        self.modelID = modelID
        self.agentMode = agentMode
        self.openCodeVersion = openCodeVersion
        self.now = now
        self.importSession = importSession
    }

    // MARK: - TranscriptWriting

    /// OpenCode's message model is text parts. Tool calls and their results are
    /// folded into readable text rather than dropped, so the next agent still
    /// knows what was run — it just does not inherit structured tool records.
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

    public func writeNative(
        _ entries: [CanonicalEntry],
        workingDirectory: URL,
        sessionID: String
    ) async throws -> ResumeHandle {
        let openCodeID = Self.openCodeSessionID(from: sessionID)
        // Raw, not standardized — see ClaudeTranscriptCodec.projectSlug.
        let directory = workingDirectory.path
        let created = Int(now().timeIntervalSince1970 * 1000)

        var messages: [[String: Any]] = []
        var previousMessageID: String?

        for (index, entry) in entries.enumerated() {
            let (role, text): (String, String)
            switch entry {
            case let .userMessage(value, _):
                (role, text) = ("user", value)
            case let .assistantMessage(value, _):
                (role, text) = ("assistant", value)
            case let .systemNote(value, _):
                (role, text) = ("assistant", value)
            case .handoffMarker, .toolUse, .toolResult, .image:
                // `sanitize(_:)` has already turned everything carryable into
                // one of the cases above.
                continue
            }
            guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }

            let messageID = Self.identifier(prefix: "msg", session: openCodeID, index: index)
            let partID = Self.identifier(prefix: "prt", session: openCodeID, index: index)
            let stamp = Int(entry.timestamp.timeIntervalSince1970 * 1000)

            // User and assistant messages do not share a schema in OpenCode's
            // export format; an assistant message carries the model and turn
            // accounting a user message has no place for.
            var info: [String: Any] = [
                "role": role,
                "agent": agentMode,
                "id": messageID,
                "sessionID": openCodeID
            ]
            if role == "user" {
                info["time"] = ["created": stamp]
                info["model"] = ["providerID": providerID, "modelID": modelID]
                info["summary"] = ["diffs": []]
            } else {
                if let previousMessageID { info["parentID"] = previousMessageID }
                info["mode"] = agentMode
                info["path"] = ["cwd": directory, "root": "/"]
                info["cost"] = 0
                info["tokens"] = [
                    "total": 0, "input": 0, "output": 0, "reasoning": 0,
                    "cache": ["write": 0, "read": 0]
                ]
                info["modelID"] = modelID
                info["providerID"] = providerID
                info["time"] = ["created": stamp, "completed": stamp]
                info["finish"] = "stop"
            }

            messages.append([
                "info": info,
                "parts": [[
                    "type": "text",
                    "text": text,
                    "id": partID,
                    "sessionID": openCodeID,
                    "messageID": messageID
                ]]
            ])
            previousMessageID = messageID
        }

        let payload: [String: Any] = [
            "info": [
                "id": openCodeID,
                "slug": "flotilla-handoff",
                "projectID": "global",
                "directory": directory,
                "path": String(directory.drop(while: { $0 == "/" })),
                "title": "Handed off to OpenCode",
                "agent": agentMode,
                "model": ["id": modelID, "providerID": providerID, "variant": "default"],
                "version": openCodeVersion,
                "summary": ["additions": 0, "deletions": 0, "files": 0],
                "cost": 0,
                "tokens": [
                    "input": 0, "output": 0, "reasoning": 0,
                    "cache": ["read": 0, "write": 0]
                ],
                "time": ["created": created, "updated": created]
            ],
            "messages": messages
        ]

        try FileManager.default.createDirectory(
            at: stagingDirectory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        let file = stagingDirectory.appendingPathComponent("\(openCodeID).json")
        let data = try JSONSerialization.data(withJSONObject: payload, options: [.withoutEscapingSlashes])
        try data.write(to: file, options: .atomic)

        try await importSession(file)

        return ResumeHandle(nativeSessionID: openCodeID, transcriptURL: file)
    }

    /// The staging file is ours; the session itself belongs to OpenCode and
    /// there is no supported way to remove it, which is exactly why a session
    /// is never handed *away* from OpenCode.
    public func removeNativeState(sessionID: String, workingDirectory: URL) throws {
        try? FileManager.default.removeItem(
            at: stagingDirectory.appendingPathComponent("\(sessionID).json")
        )
    }

    // MARK: - Identifiers

    /// OpenCode ids are `ses_`/`msg_`/`prt_` followed by an opaque token. The
    /// token is derived from the id Flotilla already pinned, so a session's
    /// OpenCode identity is reproducible from its own rather than random.
    static func openCodeSessionID(from sessionID: String) -> String {
        "ses_" + token(from: sessionID)
    }

    static func identifier(prefix: String, session: String, index: Int) -> String {
        let suffix = String(format: "%04d", index)
        return "\(prefix)_" + token(from: session).prefix(22) + suffix
    }

    private static func token(from value: String) -> String {
        let allowed = value.lowercased().filter { $0.isLetter || $0.isNumber }
        let padded = allowed + String(repeating: "0", count: max(0, 26 - allowed.count))
        return String(padded.prefix(26))
    }
}

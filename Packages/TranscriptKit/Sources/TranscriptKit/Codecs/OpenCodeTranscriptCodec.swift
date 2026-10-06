import Foundation
import SessionKit

/// Reads and writes OpenCode sessions through its supported `export`,
/// `import`, and `session delete` commands. Exported source transcripts are
/// staged in Flotilla's temporary directory; deleting a source session is an
/// explicit part of completing a handoff.
public struct OpenCodeTranscriptCodec: TranscriptReading, TranscriptWriting {
    public let agent: AgentKind = .openCode

    /// Hands a prepared export file to `opencode import`.
    ///
    /// Injected rather than executed here so this stays a pure encoder with no
    /// subprocess dependency: the app supplies a runner, tests supply a
    /// recorder. It also means the transcript is written by OpenCode itself
    /// through a supported interface, not by us reaching into its database.
    public typealias SessionImporting = @Sendable (URL) async throws -> Void
    public typealias SessionExporting = @Sendable (String, URL, URL) throws -> URL?
    public typealias SessionDeleting = @Sendable (String, URL) throws -> Void

    private let stagingDirectory: URL
    private let importSession: SessionImporting
    private let providerID: String
    private let modelID: String
    private let agentMode: String
    private let openCodeVersion: String
    private let now: @Sendable () -> Date
    private let exportSession: SessionExporting?
    private let deleteSession: SessionDeleting?

    public init(
        stagingDirectory: URL = FileManager.default.temporaryDirectory
            .appendingPathComponent("flotilla-opencode-import", isDirectory: true),
        providerID: String = "opencode",
        modelID: String = "big-pickle",
        agentMode: String = "build",
        openCodeVersion: String = "1.18.34",
        now: @escaping @Sendable () -> Date = { Date() },
        exportSession: SessionExporting? = nil,
        deleteSession: SessionDeleting? = nil,
        importSession: @escaping SessionImporting
    ) {
        self.stagingDirectory = stagingDirectory
        self.providerID = providerID
        self.modelID = modelID
        self.agentMode = agentMode
        self.openCodeVersion = openCodeVersion
        self.now = now
        self.exportSession = exportSession
        self.deleteSession = deleteSession
        self.importSession = importSession
    }

    // MARK: - TranscriptReading

    public func transcriptURL(sessionID: String, workingDirectory: URL) throws -> URL? {
        guard let exportSession else { return nil }
        try FileManager.default.createDirectory(at: stagingDirectory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        return try exportSession(sessionID, workingDirectory, stagingDirectory.appendingPathComponent("source-\(sessionID).json"))
    }

    public func embeddedSessionID(at url: URL) throws -> String? {
        let root = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any]
        return (root?["info"] as? [String: Any])?["id"] as? String
    }

    public func readNative(at url: URL) throws -> [CanonicalEntry] {
        guard let root = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any],
              let messages = root["messages"] as? [[String: Any]] else { return [] }
        var entries: [CanonicalEntry] = []
        for message in messages {
            guard let info = message["info"] as? [String: Any], let role = info["role"] as? String else { continue }
            let stamp = ((info["time"] as? [String: Any])?["created"] as? NSNumber).map { Date(timeIntervalSince1970: $0.doubleValue / 1000) } ?? .distantPast
            for part in message["parts"] as? [[String: Any]] ?? [] {
                if let text = part["text"] as? String, !text.isEmpty {
                    if role == "user" { entries.append(.userMessage(text: text, timestamp: stamp)) }
                    else if role == "assistant" { entries.append(.assistantMessage(text: text, timestamp: stamp)) }
                } else if let tool = part["tool"] as? String {
                    let state = part["state"] as? [String: Any] ?? [:]
                    let input = (try? JSONSerialization.data(withJSONObject: state["input"] ?? [:])) ?? Data()
                    let id = (part["callID"] as? String) ?? (part["id"] as? String) ?? UUID().uuidString
                    entries.append(.toolUse(id: id, tool: tool, input: input, timestamp: stamp))
                    if let output = state["output"] as? String { entries.append(.toolResult(toolUseID: id, output: output, isError: state["status"] as? String == "error", timestamp: stamp)) }
                }
            }
        }
        return entries
    }

    public func removeNativeState(sessionID: String, workingDirectory: URL) throws {
        try deleteSession?(sessionID, workingDirectory)
        try? FileManager.default.removeItem(at: stagingDirectory.appendingPathComponent("source-\(sessionID).json"))
        try? removeImportedPayload(sessionID: sessionID)
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

    /// Remove the import payload after OpenCode has accepted it.
    public func removeImportedPayload(sessionID: String) throws {
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

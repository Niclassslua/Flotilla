import Foundation
import ImageIO
import SessionKit
import UniformTypeIdentifiers

/// Reads and writes Codex CLI's rollout files under `~/.codex/sessions`.
///
/// **Layout.** `sessions/YYYY/MM/DD/rollout-<UTC timestamp>-<uuid>.jsonl`. The
/// UUID in the filename *is* the session id Codex resumes by, which is what
/// lets a handoff pin identity: write the file under an id we chose, then
/// launch `codex resume <that id>`.
///
/// **Shape.** Every line is `{timestamp, type, payload}`. Two header records
/// establish the session, then the conversation follows as `response_item`
/// records. Codex's own files also carry an `ordinal` field; it is not
/// required to load one, so it is not written.
///
/// **The two-audience problem.** Codex reads `response_item` records to build
/// the model's context, but its TUI replays `event_msg` records to draw the
/// scrollback. A file with only the former resumes into a session where the
/// model knows everything and the user sees an empty screen. So when the
/// transcript carries a handoff marker — meaning it is being written for an
/// agent that did not witness the conversation — every human-visible turn is
/// written twice, once for each audience.
public struct CodexTranscriptCodec: TranscriptReading, TranscriptWriting {
    public let agent: AgentKind = .codexCLI

    private let homeDirectory: URL
    private let cliVersion: String
    private let modelProvider: String
    private let model: String
    private let now: @Sendable () -> Date

    /// Codex records the CLI version and provider that produced a session.
    /// They are injectable rather than discovered by shelling out: this type
    /// stays free of process execution (and of a `ProcessKit` dependency),
    /// which keeps it a pure, deterministically testable file codec. The
    /// defaults match what Codex writes for a stock local install.
    public init(
        homeDirectory: URL = FileManager.agentHomeDirectory,
        cliVersion: String = "0.125.0",
        modelProvider: String = "openai",
        model: String = "gpt-5-codex",
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.homeDirectory = homeDirectory
        self.cliVersion = cliVersion
        self.modelProvider = modelProvider
        self.model = model
        self.now = now
    }

    var sessionsDirectory: URL {
        homeDirectory
            .appendingPathComponent(".codex", isDirectory: true)
            .appendingPathComponent("sessions", isDirectory: true)
    }

    // MARK: - TranscriptReading

    public func transcriptURL(sessionID: String, workingDirectory: URL) throws -> URL? {
        let suffix = "-\(sessionID).jsonl"
        guard let enumerator = FileManager.default.enumerator(
            at: sessionsDirectory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else { return nil }

        for case let url as URL in enumerator where url.lastPathComponent.hasSuffix(suffix) {
            return url
        }
        return nil
    }

    public func embeddedSessionID(at url: URL) throws -> String? {
        for line in try Self.lines(of: url) {
            guard let record = Self.decodeObject(line),
                  record["type"] as? String == "session_meta",
                  let payload = record["payload"] as? [String: Any] else { continue }
            // Codex has used both spellings across versions.
            return payload["id"] as? String ?? payload["session_id"] as? String
        }
        return nil
    }

    public func readNative(at url: URL) throws -> [CanonicalEntry] {
        var entries: [CanonicalEntry] = []

        for line in try Self.lines(of: url) {
            guard let record = Self.decodeObject(line),
                  let payload = record["payload"] as? [String: Any] else { continue }

            let timestamp = Self.parseTimestamp(record["timestamp"] as? String)

            switch record["type"] as? String {
            case "response_item":
                if let entry = Self.entry(fromResponseItem: payload, timestamp: timestamp) {
                    entries.append(entry)
                }
            case "compacted":
                if let message = payload["message"] as? String {
                    entries.append(.systemNote(text: message, timestamp: timestamp))
                }
            case "event_msg":
                // Most event_msg records mirror content already captured from
                // response_item and would duplicate every turn if read too —
                // except a viewed image, whose path exists only here (the
                // response_item behind it is opaque, harness-specific JS).
                if let entry = Self.entry(fromEventMsg: payload, timestamp: timestamp) {
                    entries.append(entry)
                }
            default:
                // session_meta, turn_context and world_state are session
                // bookkeeping, not conversation.
                continue
            }
        }

        return entries
    }

    private static func entry(
        fromResponseItem payload: [String: Any],
        timestamp: Date
    ) -> CanonicalEntry? {
        switch payload["type"] as? String {
        case "message":
            let text = flattenContent(payload["content"])
            guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
            if let note = systemNoteText(unwrapping: text) {
                return .systemNote(text: note, timestamp: timestamp)
            }
            return payload["role"] as? String == "user"
                ? .userMessage(text: text, timestamp: timestamp)
                : .assistantMessage(text: text, timestamp: timestamp)

        case "function_call":
            guard let callID = payload["call_id"] as? String,
                  let name = payload["name"] as? String else { return nil }
            // Codex stores arguments as a JSON *string*, not an object.
            let arguments = payload["arguments"] as? String ?? "{}"
            return .toolUse(id: callID, tool: name, input: Data(arguments.utf8), timestamp: timestamp)

        case "custom_tool_call":
            guard let callID = payload["call_id"] as? String,
                  let name = payload["name"] as? String else { return nil }
            let input = payload["input"] as? String ?? "{}"
            return .toolUse(id: callID, tool: name, input: Data(input.utf8), timestamp: timestamp)

        case "function_call_output", "custom_tool_call_output":
            guard let callID = payload["call_id"] as? String else { return nil }
            return .toolResult(
                toolUseID: callID,
                output: flattenContent(payload["output"]),
                isError: false,
                timestamp: timestamp
            )

        default:
            // `reasoning` lands here and is deliberately dropped on the way in
            // as well as on the way out — see `sanitize(_:)`.
            return nil
        }
    }

    /// A viewed image's path, read off disk and downsampled for the wire.
    private static func entry(fromEventMsg payload: [String: Any], timestamp: Date) -> CanonicalEntry? {
        guard payload["type"] as? String == "item_completed",
              let item = payload["item"] as? [String: Any],
              item["type"] as? String == "ImageView",
              let rawPath = item["path"] as? String
        else { return nil }

        let url = rawPath.hasPrefix("file://") ? URL(string: rawPath) : URL(fileURLWithPath: rawPath)
        guard let url, let downsampled = ImageDownsampler.downsample(at: url) else { return nil }
        return .image(mimeType: downsampled.mimeType, base64: downsampled.base64, timestamp: timestamp)
    }

    /// Codex injects a handful of its own control messages into the
    /// conversation as plain `response_item` text — not something either
    /// party said, but bookkeeping about the turn (an interruption, most
    /// commonly `<turn_aborted>…</turn_aborted>` after a stop). Read as an
    /// ordinary user message it renders as if the human typed raw XML tags,
    /// which is exactly the confusing bubble this recognises and reroutes to
    /// a system note instead.
    private static let controlTags = ["turn_aborted"]

    private static func systemNoteText(unwrapping text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        for tag in controlTags {
            let open = "<\(tag)>"
            let close = "</\(tag)>"
            guard trimmed.hasPrefix(open), trimmed.hasSuffix(close) else { continue }
            let inner = trimmed.dropFirst(open.count).dropLast(close.count)
            return inner.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return nil
    }

    /// Codex content is an array of typed parts, but plain strings appear in
    /// tool output and in older files.
    private static func flattenContent(_ content: Any?) -> String {
        if let text = content as? String { return text }
        if let parts = content as? [[String: Any]] {
            return parts.compactMap { $0["text"] as? String }.joined(separator: "\n")
        }
        if let dictionary = content as? [String: Any], let text = dictionary["text"] as? String {
            return text
        }
        return ""
    }

    // MARK: - TranscriptWriting

    /// Codex cannot represent an inline image in a rollout, and must never be
    /// handed a reasoning item — `encrypted_content` is bound to the turn and
    /// the provider that produced it, so a replayed one is at best ignored and
    /// at worst rejected. The canonical model has no reasoning case for that
    /// reason; images are dropped here.
    public func sanitize(_ entries: [CanonicalEntry]) -> [CanonicalEntry] {
        entries.filter { entry in
            if case .image = entry { return false }
            return true
        }
    }

    public func writeNative(
        _ entries: [CanonicalEntry],
        workingDirectory: URL,
        sessionID: String
    ) async throws -> ResumeHandle {
        guard Self.isUUID(sessionID) else {
            throw TranscriptCodecError.invalidSessionID(sessionID)
        }

        let timestamp = now()
        let stamp = Self.utcComponents(of: timestamp)
        let directory = sessionsDirectory
            .appendingPathComponent(stamp.year, isDirectory: true)
            .appendingPathComponent(stamp.month, isDirectory: true)
            .appendingPathComponent(stamp.day, isDirectory: true)

        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )

        let file = directory.appendingPathComponent(
            "rollout-\(stamp.fileStamp)-\(sessionID).jsonl"
        )
        let iso = Self.iso8601(timestamp)
        // Raw, not standardized — see ClaudeTranscriptCodec.projectSlug.
        let cwd = workingDirectory.path

        var lines: [String] = [
            Self.encode([
                "timestamp": iso,
                "type": "session_meta",
                "payload": [
                    "id": sessionID,
                    "timestamp": iso,
                    "cwd": cwd,
                    "originator": "codex-tui",
                    "cli_version": cliVersion,
                    "source": "cli",
                    "model_provider": modelProvider
                ]
            ]),
            Self.encode([
                "timestamp": iso,
                "type": "turn_context",
                "payload": [
                    "turn_id": UUID().uuidString.lowercased(),
                    "model": model,
                    "cwd": cwd
                ]
            ])
        ]

        // See the type's note on the two audiences.
        let mirrorForTUI = entries.contains { entry in
            if case .handoffMarker = entry { return true }
            return false
        }

        for entry in entries {
            let stampedAt = Self.iso8601(entry.timestamp)

            switch entry {
            case let .userMessage(text, _):
                if mirrorForTUI {
                    lines.append(Self.encode([
                        "timestamp": stampedAt,
                        "type": "event_msg",
                        "payload": [
                            "type": "user_message",
                            "message": text,
                            "images": [], "local_images": [],
                            "audio": [], "local_audio": [],
                            "text_elements": []
                        ]
                    ]))
                }
                lines.append(Self.encode([
                    "timestamp": stampedAt,
                    "type": "response_item",
                    "payload": [
                        "type": "message",
                        "role": "user",
                        "content": [["type": "input_text", "text": text]]
                    ]
                ]))

            case let .assistantMessage(text, _):
                if mirrorForTUI {
                    lines.append(Self.encode([
                        "timestamp": stampedAt,
                        "type": "event_msg",
                        "payload": [
                            "type": "agent_message",
                            "message": text,
                            "phase": "final_answer",
                            "memory_citation": NSNull()
                        ]
                    ]))
                }
                lines.append(Self.encode([
                    "timestamp": stampedAt,
                    "type": "response_item",
                    "payload": [
                        "type": "message",
                        "role": "assistant",
                        "content": [["type": "output_text", "text": text]]
                    ]
                ]))

            case let .toolUse(id, tool, input, _):
                if mirrorForTUI {
                    lines.append(Self.commentary(
                        Self.toolCallSummary(tool: tool, input: input),
                        at: stampedAt
                    ))
                }
                lines.append(Self.encode([
                    "timestamp": stampedAt,
                    "type": "response_item",
                    "payload": [
                        "type": "function_call",
                        "call_id": id,
                        "name": tool,
                        "arguments": String(data: input, encoding: .utf8) ?? "{}"
                    ]
                ]))

            case let .toolResult(toolUseID, output, isError, _):
                // A failed tool is worth showing; a successful one is usually
                // large and the model already has it in full below.
                if mirrorForTUI, isError {
                    lines.append(Self.commentary("\u{26A0} \(Self.truncate(output, to: 200))", at: stampedAt))
                }
                // Codex's `function_call_output` has no error field, so a
                // failed tool reads back as an ordinary result. Inventing one
                // is worse than losing it: an unrecognised key is at best
                // ignored and at worst makes the record unparseable. The
                // failure is still legible to the model because it is in the
                // output text — which is where a real tool puts it too, and
                // where `ToolCallPairing` puts its placeholder.
                lines.append(Self.encode([
                    "timestamp": stampedAt,
                    "type": "response_item",
                    "payload": [
                        "type": "function_call_output",
                        "call_id": toolUseID,
                        "output": output
                    ]
                ]))

            case let .systemNote(text, _):
                // `compacted` is Codex's own carrier for text that belongs to
                // the session but to neither speaker.
                lines.append(Self.encode([
                    "timestamp": stampedAt,
                    "type": "compacted",
                    "payload": ["message": text]
                ]))

            case .image, .handoffMarker:
                // Images are removed by `sanitize(_:)`; the marker has done its
                // job by the time we get here — it selected the TUI mirror.
                continue
            }
        }

        try lines.joined(separator: "\n").write(to: file, atomically: true, encoding: .utf8)
        return ResumeHandle(nativeSessionID: sessionID, transcriptURL: file)
    }

    public func removeNativeState(sessionID: String, workingDirectory: URL) throws {
        guard let url = try transcriptURL(sessionID: sessionID, workingDirectory: workingDirectory) else {
            return
        }
        try? FileManager.default.removeItem(at: url)
    }

    // MARK: - Encoding helpers

    /// Codex draws tool activity from `item_completed` records carrying
    /// `CommandExecution` items — a shape built from live process state
    /// (`process_id`, a `file://` cwd, a `parsed_cmd` breakdown) that a
    /// transcode simply does not have. Fabricating one risks a record Codex
    /// cannot parse, which would cost us the resume that currently works.
    ///
    /// So carried-over tool activity is mirrored as commentary instead: the
    /// user sees that the previous agent ran something and what it was, and
    /// nothing invented reaches the model, which reads the real `function_call`
    /// records below. Presentation only, and deliberately modest.
    static func commentary(_ message: String, at timestamp: String) -> String {
        encode([
            "timestamp": timestamp,
            "type": "event_msg",
            "payload": [
                "type": "agent_message",
                "message": message,
                "phase": "commentary",
                "memory_citation": NSNull()
            ]
        ])
    }

    /// A one-line rendering of a tool call. Prefers the arguments a human would
    /// recognise — a command, a path, a pattern — over dumping the JSON.
    static func toolCallSummary(tool: String, input: Data) -> String {
        let arguments = (try? JSONSerialization.jsonObject(with: input)) as? [String: Any]
        let interesting = ["command", "cmd", "path", "file_path", "pattern", "query", "url"]

        var detail: String?
        if let arguments {
            for key in interesting {
                guard let value = arguments[key] else { continue }
                if let list = value as? [String] {
                    detail = list.joined(separator: " ")
                } else if let text = value as? String {
                    detail = text
                }
                if detail != nil { break }
            }
            if detail == nil, !arguments.isEmpty,
               let json = try? JSONSerialization.data(withJSONObject: arguments),
               let text = String(data: json, encoding: .utf8) {
                detail = text
            }
        }

        guard let detail, !detail.isEmpty else { return "\u{2699} \(tool)" }
        return "\u{2699} \(tool)  \(truncate(detail, to: 160))"
    }

    static func truncate(_ text: String, to limit: Int) -> String {
        let flattened = text
            .split(separator: "\n", omittingEmptySubsequences: true)
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespaces)
        guard flattened.count > limit else { return flattened }
        return flattened.prefix(limit) + "\u{2026}"
    }

    static func isUUID(_ value: String) -> Bool {
        UUID(uuidString: value) != nil
    }

    private static func encode(_ object: [String: Any]) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.withoutEscapingSlashes]),
              let json = String(data: data, encoding: .utf8)
        else { return "{}" }
        return json
    }

    static func lines(of url: URL) throws -> [Substring] {
        try String(contentsOf: url, encoding: .utf8)
            .split(separator: "\n", omittingEmptySubsequences: true)
    }

    static func decodeObject(_ line: Substring) -> [String: Any]? {
        guard let data = line.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        return object
    }

    private static let style = Date.ISO8601FormatStyle(includingFractionalSeconds: true)
    private static let plainStyle = Date.ISO8601FormatStyle()

    static func iso8601(_ date: Date) -> String {
        date.formatted(style)
    }

    static func parseTimestamp(_ raw: String?) -> Date {
        guard let raw else { return Date() }
        if let date = try? style.parse(raw) { return date }
        if let date = try? plainStyle.parse(raw) { return date }
        return Date()
    }

    /// Codex nests rollouts by UTC date and stamps the filename with a
    /// dash-separated UTC time. Built from `Calendar` rather than a
    /// `DateFormatter` because formatters are reference types and cannot be
    /// shared statics under strict concurrency.
    static func utcComponents(of date: Date) -> (year: String, month: String, day: String, fileStamp: String) {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let parts = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)

        func pad(_ value: Int?) -> String { String(format: "%02d", value ?? 0) }
        let year = String(parts.year ?? 1970)
        let month = pad(parts.month)
        let day = pad(parts.day)
        let stamp = "\(year)-\(month)-\(day)T\(pad(parts.hour))-\(pad(parts.minute))-\(pad(parts.second))"
        return (year, month, day, stamp)
    }
}

extension CodexTranscriptCodec {
    /// Codex mints its own session id, so a session Flotilla launched has no id
    /// until something reads it back. Rollouts do record their `cwd`, so this
    /// can match on both the working directory and the launch time rather than
    /// on time alone.
    public func discoverSession(workingDirectory: URL, since: Date) throws -> (sessionID: String, url: URL)? {
        guard let enumerator = FileManager.default.enumerator(
            at: sessionsDirectory,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else { return nil }

        let wanted = workingDirectory.path
        var best: (sessionID: String, url: URL, modified: Date)?

        for case let url as URL in enumerator {
            guard url.pathExtension == "jsonl",
                  url.lastPathComponent.hasPrefix("rollout-"),
                  let modified = try? url.resourceValues(forKeys: [.contentModificationDateKey])
                      .contentModificationDate,
                  modified >= since
            else { continue }

            guard let sessionID = (try? embeddedSessionID(at: url)) ?? nil else { continue }
            guard Self.recordedWorkingDirectory(at: url) == wanted else { continue }

            if best == nil || modified > best!.modified {
                best = (sessionID, url, modified)
            }
        }

        guard let best else { return nil }
        return (best.sessionID, best.url)
    }

    /// The `cwd` a rollout's `session_meta` claims, without parsing the rest.
    static func recordedWorkingDirectory(at url: URL) -> String? {
        guard let lines = try? lines(of: url) else { return nil }
        for line in lines.prefix(4) {
            guard let record = decodeObject(line),
                  record["type"] as? String == "session_meta",
                  let payload = record["payload"] as? [String: Any]
            else { continue }
            return payload["cwd"] as? String
        }
        return nil
    }
}

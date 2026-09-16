import Foundation
import SessionKit

/// Reads and writes Claude Code's transcripts under `~/.claude/projects`.
///
/// **Layout.** One JSONL file per session, named by the session UUID, inside a
/// directory named for the working directory with every `/` replaced by `-`.
/// That mapping is ambiguous — a path component containing a dash is
/// indistinguishable from a separator — so `transcriptURL` treats the slug as
/// a hint and falls back to matching the file by name, which is exact because
/// the filename *is* the session id.
///
/// **Shape.** Records are a linked list: each carries `uuid` and `parentUuid`,
/// and Claude will not load a transcript whose chain is broken. The file also
/// interleaves a dozen sidecar record types (`mode`, `cost-state`,
/// `file-history-snapshot`, …) that have nothing to do with the conversation;
/// reading filters to `user` and `assistant` and ignores the rest.
public struct ClaudeTranscriptCodec: TranscriptLineReading, TranscriptWriting {
    public let agent: AgentKind = .claudeCode

    private let homeDirectory: URL
    private let cliVersion: String
    private let permissionMode: String
    private let gitBranch: String?

    /// `homeDirectory` is injectable so tests can build a transcript tree in a
    /// temporary directory rather than touching the developer's real one.
    ///
    /// The remaining values are session metadata Claude stamps on every record.
    /// They are injected rather than discovered here so this type stays a pure
    /// file codec with no subprocess or git dependency; the defaults are what a
    /// stock install writes.
    public init(
        homeDirectory: URL = FileManager.agentHomeDirectory,
        cliVersion: String = "2.1.119",
        permissionMode: String = "default",
        gitBranch: String? = nil
    ) {
        self.homeDirectory = homeDirectory
        self.cliVersion = cliVersion
        self.permissionMode = permissionMode
        self.gitBranch = gitBranch
    }

    var projectsDirectory: URL {
        homeDirectory
            .appendingPathComponent(".claude", isDirectory: true)
            .appendingPathComponent("projects", isDirectory: true)
    }

    /// Claude's directory name for a working directory: the absolute path with
    /// every separator turned into a dash, leading separator included.
    ///
    /// Deliberately *not* standardized. `standardizedFileURL` resolves symlinks
    /// only for paths that exist — so `/private/tmp/x` becomes `/tmp/x` once the
    /// directory is created and stays `/private/tmp/x` before that. Feeding it
    /// here would make a session's transcript location depend on whether its
    /// worktree happened to exist at the moment of the call, and a handoff
    /// would write into a directory the agent never reads. The raw path is what
    /// Flotilla also hands the process as its working directory, so deriving
    /// the slug from it keeps the two in step.
    static func projectSlug(for workingDirectory: URL) -> String {
        workingDirectory.path.replacingOccurrences(of: "/", with: "-")
    }

    // MARK: - TranscriptReading

    public func transcriptURL(sessionID: String, workingDirectory: URL) throws -> URL? {
        let fileName = "\(sessionID).jsonl"

        let expected = projectsDirectory
            .appendingPathComponent(Self.projectSlug(for: workingDirectory), isDirectory: true)
            .appendingPathComponent(fileName)
        if FileManager.default.fileExists(atPath: expected.path) { return expected }

        // The slug did not resolve — an ambiguous dash, or a session started
        // from a symlinked path. The filename is the session id, so a scan
        // over the project directories still identifies it exactly.
        let projects = (try? FileManager.default.contentsOfDirectory(
            at: projectsDirectory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )) ?? []

        for project in projects {
            let candidate = project.appendingPathComponent(fileName)
            if FileManager.default.fileExists(atPath: candidate.path) { return candidate }
        }
        return nil
    }

    public func embeddedSessionID(at url: URL) throws -> String? {
        for line in try Self.lines(of: url) {
            guard let object = Self.decodeObject(line) else { continue }
            if let sessionID = object["sessionId"] as? String, !sessionID.isEmpty {
                return sessionID
            }
        }
        return nil
    }

    public func readNative(at url: URL) throws -> [CanonicalEntry] {
        readRecords(try Self.lines(of: url))
    }

    public func readRecords(_ lines: [Substring]) -> [CanonicalEntry] {
        var entries: [CanonicalEntry] = []

        for line in lines {
            guard let record = Self.decodeObject(line) else { continue }

            // Sidechain records are a subagent's own conversation. Splicing
            // them into the main thread would interleave two chains into one
            // garbled history, so they are left behind with the agent.
            if record["isSidechain"] as? Bool == true { continue }

            guard let type = record["type"] as? String,
                  type == "user" || type == "assistant",
                  let message = record["message"] as? [String: Any] else { continue }

            let timestamp = Self.parseTimestamp(record["timestamp"] as? String)
            entries.append(contentsOf: Self.entries(from: message, type: type, timestamp: timestamp))
        }

        return entries
    }

    // MARK: - Record decoding

    private static func entries(
        from message: [String: Any],
        type: String,
        timestamp: Date
    ) -> [CanonicalEntry] {
        // Claude writes user text as a bare string and everything richer as an
        // array of typed blocks.
        if let text = message["content"] as? String {
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, !(type == "user" && isSyntheticUserText(trimmed)) else { return [] }
            return [type == "user"
                ? .userMessage(text: text, timestamp: timestamp)
                : .assistantMessage(text: text, timestamp: timestamp)]
        }

        guard let blocks = message["content"] as? [[String: Any]] else { return [] }

        var entries: [CanonicalEntry] = []

        for block in blocks {
            switch block["type"] as? String {
            case "text":
                guard let text = block["text"] as? String else { continue }
                let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty, !(type == "user" && isSyntheticUserText(trimmed)) else { continue }
                entries.append(type == "user"
                    ? .userMessage(text: text, timestamp: timestamp)
                    : .assistantMessage(text: text, timestamp: timestamp))

            case "tool_use":
                guard let id = block["id"] as? String,
                      let name = block["name"] as? String else { continue }
                let input = block["input"] ?? [String: Any]()
                entries.append(.toolUse(
                    id: id,
                    tool: name,
                    input: Self.encodeJSON(input),
                    timestamp: timestamp
                ))
                if name == "SendUserFile",
                   let dict = input as? [String: Any],
                   let files = dict["files"] as? [String] {
                    for path in files where isImagePath(path) {
                        let url = path.hasPrefix("file://") ? URL(string: path) : URL(fileURLWithPath: path)
                        if let url, let downsampled = ImageDownsampler.downsample(at: url) {
                            entries.append(.image(
                                mimeType: downsampled.mimeType,
                                base64: downsampled.base64,
                                timestamp: timestamp
                            ))
                        }
                    }
                }

            case "tool_result":
                guard let toolUseID = block["tool_use_id"] as? String else { continue }
                entries.append(.toolResult(
                    toolUseID: toolUseID,
                    output: Self.flatten(block["content"]),
                    isError: block["is_error"] as? Bool ?? false,
                    timestamp: timestamp
                ))
                if let contentBlocks = block["content"] as? [[String: Any]] {
                    for contentBlock in contentBlocks {
                        if contentBlock["type"] as? String == "image",
                           let source = contentBlock["source"] as? [String: Any],
                           let data = source["data"] as? String {
                            let mime = source["media_type"] as? String ?? "image/png"
                            if let rawData = Data(base64Encoded: data),
                               let downsampled = ImageDownsampler.downsample(data: rawData) {
                                entries.append(.image(
                                    mimeType: downsampled.mimeType,
                                    base64: downsampled.base64,
                                    timestamp: timestamp
                                ))
                            } else {
                                entries.append(.image(
                                    mimeType: mime,
                                    base64: data,
                                    timestamp: timestamp
                                ))
                            }
                        }
                    }
                }

            case "image":
                guard let source = block["source"] as? [String: Any],
                      let data = source["data"] as? String else { continue }
                let mime = source["media_type"] as? String ?? "image/png"
                if let rawData = Data(base64Encoded: data),
                   let downsampled = ImageDownsampler.downsample(data: rawData) {
                    entries.append(.image(
                        mimeType: downsampled.mimeType,
                        base64: downsampled.base64,
                        timestamp: timestamp
                    ))
                } else {
                    entries.append(.image(
                        mimeType: mime,
                        base64: data,
                        timestamp: timestamp
                    ))
                }

            default:
                // Thinking blocks and anything added upstream since. Skipping
                // is deliberate: these formats gain block types between
                // releases and a strict reader would break on each one.
                continue
            }
        }

        return entries
    }

    private static let imageExtensions: Set<String> = [
        "png", "jpg", "jpeg", "gif", "webp", "bmp", "tiff", "heic"
    ]

    private static func isImagePath(_ path: String) -> Bool {
        let ext = (path as NSString).pathExtension.lowercased()
        return imageExtensions.contains(ext)
    }

    /// Claude Code injects harness plumbing — background-task notifications,
    /// reminders — as plain text on a `user`-role turn, since that's the only
    /// role the API accepts for non-assistant content. A human never typed
    /// this, so it must not render as a chat message the human sent.
    private static func isSyntheticUserText(_ trimmed: String) -> Bool {
        trimmed.hasPrefix("<system-reminder")
            || trimmed.hasPrefix("<task-notification")
            || trimmed.hasPrefix("[SYSTEM NOTIFICATION")
    }

    /// A tool result's content is a string, or blocks, or occasionally neither.
    private static func flatten(_ content: Any?) -> String {
        if let text = content as? String { return text }
        if let blocks = content as? [[String: Any]] {
            return blocks.compactMap { $0["text"] as? String }.joined(separator: "\n")
        }
        if let value = content { return String(describing: value) }
        return ""
    }

    // MARK: - Shared helpers

    static func lines(of url: URL) throws -> [Substring] {
        let contents = try String(contentsOf: url, encoding: .utf8)
        return contents.split(separator: "\n", omittingEmptySubsequences: true)
    }

    static func decodeObject(_ line: Substring) -> [String: Any]? {
        guard let data = line.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        return object
    }

    static func encodeJSON(_ value: Any) -> Data {
        guard JSONSerialization.isValidJSONObject(value),
              let data = try? JSONSerialization.data(withJSONObject: value)
        else { return Data("{}".utf8) }
        return data
    }

    // `ISO8601DateFormatter` is a class and not `Sendable`, so it cannot be a
    // shared static under strict concurrency. The format *style* is a value
    // type and is, which is why these are styles rather than formatters.
    private static let fractionalStyle = Date.ISO8601FormatStyle(includingFractionalSeconds: true)
    private static let plainStyle = Date.ISO8601FormatStyle()

    /// Claude stamps with fractional seconds. A missing or unparseable stamp
    /// falls back to now rather than dropping the entry — losing a turn is a
    /// worse outcome than misplacing it by a few seconds, and the entries are
    /// already in file order.
    static func parseTimestamp(_ raw: String?) -> Date {
        guard let raw else { return Date() }
        if let date = try? fractionalStyle.parse(raw) { return date }
        if let date = try? plainStyle.parse(raw) { return date }
        return Date()
    }
}

// MARK: - TranscriptWriting

extension ClaudeTranscriptCodec {
    /// Claude carries every canonical case, so nothing is dropped. The one
    /// transformation is structural and happens during the write: a run of
    /// assistant text and tool calls has to become a single record.
    public func sanitize(_ entries: [CanonicalEntry]) -> [CanonicalEntry] {
        entries
    }

    /// Writes a transcript Claude will resume from.
    ///
    /// Two invariants make this more than a serialisation loop. First, records
    /// form a linked list through `uuid`/`parentUuid`, and Claude will not load
    /// a broken chain — so the chain head is threaded through the whole walk.
    /// Second, a turn is one record: consecutive assistant text and tool calls
    /// coalesce into one `assistant` record of content blocks, and consecutive
    /// tool results coalesce into the single `user` record that answers them.
    public func writeNative(
        _ entries: [CanonicalEntry],
        workingDirectory: URL,
        sessionID: String
    ) async throws -> ResumeHandle {
        let directory = projectsDirectory
            .appendingPathComponent(Self.projectSlug(for: workingDirectory), isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        let file = directory.appendingPathComponent("\(sessionID).jsonl")

        var envelope: [String: Any] = [
            "cwd": workingDirectory.path,
            "sessionId": sessionID,
            "version": cliVersion,
            "userType": "external",
            "entrypoint": "cli",
            "permissionMode": permissionMode,
            "isSidechain": false
        ]
        if let gitBranch { envelope["gitBranch"] = gitBranch }

        var lines: [String] = [
            Self.encode([
                "type": "permission-mode",
                "permissionMode": permissionMode,
                "sessionId": sessionID
            ])
        ]

        // The chain head: `nil` until the first conversational record lands.
        var parentUUID: String?

        /// Emits one chained record and advances the chain.
        func appendChained(_ fields: [String: Any], at timestamp: Date) {
            let uuid = UUID().uuidString
            var record = envelope
            record["uuid"] = uuid
            record["parentUuid"] = parentUUID as Any? ?? NSNull()
            record["promptId"] = UUID().uuidString
            record["timestamp"] = Self.iso8601(timestamp)
            for (key, value) in fields { record[key] = value }
            lines.append(Self.encode(record))
            parentUUID = uuid
        }

        var index = 0
        while index < entries.count {
            switch entries[index] {
            case let .userMessage(text, timestamp):
                appendChained([
                    "type": "user",
                    "message": ["role": "user", "content": text]
                ], at: timestamp)
                index += 1

            case .assistantMessage, .toolUse:
                var blocks: [[String: Any]] = []
                var pendingText = ""
                let timestamp = entries[index].timestamp

                turn: while index < entries.count {
                    switch entries[index] {
                    case let .assistantMessage(text, _):
                        pendingText += pendingText.isEmpty ? text : "\n\n" + text
                    case let .toolUse(id, tool, input, _):
                        if !pendingText.isEmpty {
                            blocks.append(["type": "text", "text": pendingText])
                            pendingText = ""
                        }
                        blocks.append([
                            "type": "tool_use",
                            "id": id,
                            "name": tool,
                            "input": (try? JSONSerialization.jsonObject(with: input)) ?? [String: Any]()
                        ])
                    default:
                        break turn
                    }
                    index += 1
                }
                if !pendingText.isEmpty {
                    blocks.append(["type": "text", "text": pendingText])
                }
                guard !blocks.isEmpty else { continue }

                appendChained([
                    "type": "assistant",
                    "requestId": UUID().uuidString,
                    "message": [
                        "role": "assistant",
                        "content": blocks,
                        "model": Self.syntheticModel,
                        "stop_reason": "end_turn",
                        "usage": [
                            "input_tokens": 0,
                            "output_tokens": 0,
                            "cache_read_input_tokens": 0,
                            "cache_creation_input_tokens": 0
                        ]
                    ]
                ], at: timestamp)

            case .toolResult:
                var blocks: [[String: Any]] = []
                let timestamp = entries[index].timestamp

                while index < entries.count, case let .toolResult(toolUseID, output, isError, _) = entries[index] {
                    var block: [String: Any] = [
                        "type": "tool_result",
                        "tool_use_id": toolUseID,
                        "content": output
                    ]
                    if isError { block["is_error"] = true }
                    blocks.append(block)
                    index += 1
                }

                // A user message that immediately follows tool results belongs
                // in the *same* record: the results and the reply are one user
                // turn, and splitting them puts an empty turn in between.
                if index < entries.count, case let .userMessage(text, _) = entries[index] {
                    blocks.append(["type": "text", "text": text])
                    index += 1
                }

                appendChained([
                    "type": "user",
                    "message": ["role": "user", "content": blocks]
                ], at: timestamp)

            case let .image(mimeType, base64, timestamp):
                appendChained([
                    "type": "user",
                    "message": [
                        "role": "user",
                        "content": [[
                            "type": "image",
                            "source": ["type": "base64", "media_type": mimeType, "data": base64]
                        ]]
                    ]
                ], at: timestamp)
                index += 1

            case let .systemNote(text, timestamp):
                // System records sit outside the chain — they are not a turn,
                // and threading them would make the conversation's parent links
                // step through something neither party said.
                var record = envelope
                record["type"] = "system"
                record["subtype"] = "local_command"
                record["content"] = text
                record["timestamp"] = Self.iso8601(timestamp)
                lines.append(Self.encode(record))
                index += 1

            case .handoffMarker:
                // Claude has no record type for it, and unlike Codex it needs
                // no replay hint — it renders the conversation from the same
                // records the model reads.
                index += 1
            }
        }

        try lines.joined(separator: "\n").write(to: file, atomically: true, encoding: .utf8)
        return ResumeHandle(nativeSessionID: sessionID, transcriptURL: file)
    }

    /// Claude spreads a session across several directories. Leaving any of them
    /// behind lets it believe it still owns a conversation that has moved on.
    ///
    /// Every removal is best-effort by contract: a session that never created a
    /// todo list has no todo file, and that is not a failure.
    public func removeNativeState(sessionID: String, workingDirectory: URL) throws {
        let claude = homeDirectory.appendingPathComponent(".claude", isDirectory: true)
        var targets: [URL] = [
            claude.appendingPathComponent("todos/\(sessionID)-agent-\(sessionID).json"),
            claude.appendingPathComponent("debug/\(sessionID).txt"),
            claude.appendingPathComponent("session-env/\(sessionID)", isDirectory: true),
            claude.appendingPathComponent("tasks/\(sessionID)", isDirectory: true),
            claude.appendingPathComponent("file-history/\(sessionID)", isDirectory: true)
        ]

        if let transcript = try transcriptURL(sessionID: sessionID, workingDirectory: workingDirectory) {
            targets.append(transcript)
        }

        let telemetry = claude.appendingPathComponent("telemetry", isDirectory: true)
        let failedEventsPrefix = "1p_failed_events.\(sessionID)."
        let telemetryFiles = (try? FileManager.default.contentsOfDirectory(
            at: telemetry,
            includingPropertiesForKeys: nil
        )) ?? []
        targets.append(contentsOf: telemetryFiles.filter { $0.lastPathComponent.hasPrefix(failedEventsPrefix) })

        for target in targets {
            try? FileManager.default.removeItem(at: target)
        }
    }

    /// Claude records the model that produced each assistant turn. A moved
    /// conversation was not produced by any Claude model, so this is a stand-in
    /// rather than a claim — it is display metadata, never replayed as a
    /// request parameter.
    static let syntheticModel = "claude-sonnet-4-6"

    private static let writeStyle = Date.ISO8601FormatStyle(includingFractionalSeconds: true)

    static func iso8601(_ date: Date) -> String {
        date.formatted(writeStyle)
    }

    static func encode(_ object: [String: Any]) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.withoutEscapingSlashes]),
              let json = String(data: data, encoding: .utf8)
        else { return "{}" }
        return json
    }
}

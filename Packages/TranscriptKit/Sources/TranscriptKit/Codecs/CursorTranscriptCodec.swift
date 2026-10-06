import CryptoKit
import Foundation
import SessionKit

/// Reads and writes Cursor Agent CLI conversations.
///
/// **Layout.** Chat state lives under `~/.cursor/chats/<md5(cwd)>/<chatId>/`
/// (`meta.json` + opaque `store.db`). A parallel display transcript is
/// `~/.cursor/projects/<slug>/agent-transcripts/<chatId>/<chatId>.jsonl` —
/// thin `{role,message.content[]}` records. Companion cold-load and handoff
/// *source* read the JSONL. Handoff *destination* writes the JSONL + meta,
/// then seeds `store.db` through an injected runner (Cursor's store format is
/// an encrypted blob DAG; the supported way to create a resumeable chat is to
/// let `agent --resume` itself write the store — verified locally).
public struct CursorTranscriptCodec: TranscriptLineReading, TranscriptWriting {
    public let agent: AgentKind = .cursorAgent

    public typealias StoreSeeding = @Sendable (_ sessionID: String, _ workingDirectory: URL, _ entries: [CanonicalEntry]) async throws -> Void

    private let homeDirectory: URL
    private let seedStore: StoreSeeding?
    private let now: @Sendable () -> Date

    public init(
        homeDirectory: URL = FileManager.agentHomeDirectory,
        now: @escaping @Sendable () -> Date = { Date() },
        seedStore: StoreSeeding? = nil
    ) {
        self.homeDirectory = homeDirectory
        self.now = now
        self.seedStore = seedStore
    }

    var cursorHome: URL {
        homeDirectory.appendingPathComponent(".cursor", isDirectory: true)
    }

    var projectsDirectory: URL {
        cursorHome.appendingPathComponent("projects", isDirectory: true)
    }

    var chatsDirectory: URL {
        cursorHome.appendingPathComponent("chats", isDirectory: true)
    }

    // MARK: - Path helpers

    /// Cursor's project directory name: absolute path with `/` → `-`, often
    /// with a `private-` prefix when the real path is under `/private`.
    public static func projectSlugCandidates(for workingDirectory: URL) -> [String] {
        let path = workingDirectory.path
        let withoutPrivate = path.replacingOccurrences(of: "/private", with: "", options: [.anchored])
        return [
            path.replacingOccurrences(of: "/", with: "-").trimmingCharacters(in: CharacterSet(charactersIn: "-")),
            withoutPrivate.replacingOccurrences(of: "/", with: "-").trimmingCharacters(in: CharacterSet(charactersIn: "-")),
            "private" + path.replacingOccurrences(of: "/", with: "-"),
            ("private-" + withoutPrivate.replacingOccurrences(of: "/", with: "-")
                .trimmingCharacters(in: CharacterSet(charactersIn: "-"))),
        ]
    }

    /// Chat parent directories are `md5(realpath(cwd))` hex digests.
    public static func chatBucketHash(for cwdPath: String) -> String {
        let data = Data(cwdPath.utf8)
        return Insecure.MD5.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    public func chatDirectory(sessionID: String, workingDirectory: URL) -> URL {
        chatsDirectory
            .appendingPathComponent(Self.chatBucketHash(for: workingDirectory.path), isDirectory: true)
            .appendingPathComponent(sessionID, isDirectory: true)
    }

    // MARK: - TranscriptReading

    public func transcriptURL(sessionID: String, workingDirectory: URL) throws -> URL? {
        let fileName = "\(sessionID).jsonl"
        for slug in Self.projectSlugCandidates(for: workingDirectory) {
            let url = projectsDirectory
                .appendingPathComponent(slug, isDirectory: true)
                .appendingPathComponent("agent-transcripts", isDirectory: true)
                .appendingPathComponent(sessionID, isDirectory: true)
                .appendingPathComponent(fileName)
            if FileManager.default.fileExists(atPath: url.path) { return url }
        }
        let projects = (try? FileManager.default.contentsOfDirectory(
            at: projectsDirectory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )) ?? []
        for project in projects {
            let url = project
                .appendingPathComponent("agent-transcripts", isDirectory: true)
                .appendingPathComponent(sessionID, isDirectory: true)
                .appendingPathComponent(fileName)
            if FileManager.default.fileExists(atPath: url.path) { return url }
        }
        return nil
    }

    public func embeddedSessionID(at url: URL) throws -> String? {
        // Cursor JSONL does not stamp sessionId on records; the directory /
        // filename *is* the chat id.
        let name = url.deletingPathExtension().lastPathComponent
        return UUID(uuidString: name) != nil ? name : url.deletingLastPathComponent().lastPathComponent
    }

    public func readNative(at url: URL) throws -> [CanonicalEntry] {
        readRecords(try Self.lines(of: url))
    }

    public func readRecords(_ lines: [Substring]) -> [CanonicalEntry] {
        var entries: [CanonicalEntry] = []
        let stamp = now()
        for line in lines {
            guard let record = Self.decodeObject(line) else { continue }
            // Cursor keeps only the latest `turn_ended` and drops it when the
            // next turn starts, so this note lasts until the user goes on.
            if record["type"] as? String == "turn_ended", record["status"] as? String == "error" {
                let reason = record["error"] as? String
                entries.append(.systemNote(
                    text: "Cursor stopped with an error" + (reason.map { ": \($0)" } ?? "."),
                    timestamp: stamp
                ))
                continue
            }
            let role = record["role"] as? String
            let message = record["message"] as? [String: Any] ?? record
            let content = message["content"]
            let texts = Self.flattenText(content)
            guard let role, !texts.isEmpty else { continue }
            let text = texts
                .map(Self.stripHarnessWrappers)
                // Some models' end-of-sequence token leaks into the reply.
                .map { $0.replacingOccurrences(of: "<|eos|>", with: "").trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty && $0 != "[REDACTED]" }
                .joined(separator: "\n")
            guard !text.isEmpty else { continue }
            switch role {
            case "user":
                entries.append(.userMessage(text: text, timestamp: stamp))
            case "assistant":
                entries.append(.assistantMessage(text: text, timestamp: stamp))
            default:
                continue
            }
        }
        return entries
    }

    public func discoverSession(workingDirectory: URL, since: Date) throws -> (sessionID: String, url: URL)? {
        let bucket = chatsDirectory.appendingPathComponent(
            Self.chatBucketHash(for: workingDirectory.path),
            isDirectory: true
        )
        guard FileManager.default.fileExists(atPath: bucket.path) else { return nil }
        let dirs = (try? FileManager.default.contentsOfDirectory(
            at: bucket,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        )) ?? []
        let sorted = dirs.sorted { a, b in
            let dateA = (try? a.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            let dateB = (try? b.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            return dateA > dateB
        }
        for dir in sorted {
            let metaURL = dir.appendingPathComponent("meta.json")
            guard let data = try? Data(contentsOf: metaURL),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }
            let updatedMs = json["updatedAtMs"] as? Double ?? json["createdAtMs"] as? Double
            let updated = updatedMs.map { Date(timeIntervalSince1970: $0 / 1000) }
                ?? ((try? dir.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast)
            guard updated >= since else { continue }
            let id = dir.lastPathComponent
            if let url = try transcriptURL(sessionID: id, workingDirectory: workingDirectory) {
                return (id, url)
            }
            return (id, metaURL)
        }
        return nil
    }

    // MARK: - TranscriptWriting

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
        guard UUID(uuidString: sessionID) != nil else {
            throw TranscriptCodecError.invalidSessionID(sessionID)
        }

        let slug = Self.projectSlugCandidates(for: workingDirectory)[0]
        let transcriptDir = projectsDirectory
            .appendingPathComponent(slug, isDirectory: true)
            .appendingPathComponent("agent-transcripts", isDirectory: true)
            .appendingPathComponent(sessionID, isDirectory: true)
        try FileManager.default.createDirectory(at: transcriptDir, withIntermediateDirectories: true)
        let transcriptURL = transcriptDir.appendingPathComponent("\(sessionID).jsonl")

        var lines: [String] = []
        for entry in entries {
            switch entry {
            case let .userMessage(text, _):
                lines.append(Self.encodeJSONL(role: "user", text: Self.wrapUserQuery(text)))
            case let .assistantMessage(text, _):
                lines.append(Self.encodeJSONL(role: "assistant", text: text))
            case let .systemNote(text, _):
                lines.append(Self.encodeJSONL(role: "user", text: Self.wrapUserQuery(text)))
            case let .handoffMarker(from, to, reason, _):
                let note = "Handed off from \(from.displayName) to \(to.displayName): \(reason)"
                lines.append(Self.encodeJSONL(role: "user", text: Self.wrapUserQuery(note)))
            default:
                continue
            }
        }
        try (lines.joined(separator: "\n") + (lines.isEmpty ? "" : "\n"))
            .write(to: transcriptURL, atomically: true, encoding: .utf8)

        let chatDir = chatDirectory(sessionID: sessionID, workingDirectory: workingDirectory)
        try FileManager.default.createDirectory(at: chatDir, withIntermediateDirectories: true)
        let nowMs = Int(now().timeIntervalSince1970 * 1000)
        let meta: [String: Any] = [
            "schemaVersion": 1,
            "createdAtMs": nowMs,
            "updatedAtMs": nowMs,
            "hasConversation": !lines.isEmpty,
            "cwd": workingDirectory.path,
            "title": "Flotilla handoff"
        ]
        let metaData = try JSONSerialization.data(withJSONObject: meta, options: [.sortedKeys])
        try metaData.write(to: chatDir.appendingPathComponent("meta.json"), options: .atomic)

        if let seedStore {
            try await seedStore(sessionID, workingDirectory, entries)
        }

        return ResumeHandle(nativeSessionID: sessionID, transcriptURL: transcriptURL)
    }

    public func removeNativeState(sessionID: String, workingDirectory: URL) throws {
        let chatDir = chatDirectory(sessionID: sessionID, workingDirectory: workingDirectory)
        try? FileManager.default.removeItem(at: chatDir)
        for slug in Self.projectSlugCandidates(for: workingDirectory) {
            let dir = projectsDirectory
                .appendingPathComponent(slug, isDirectory: true)
                .appendingPathComponent("agent-transcripts", isDirectory: true)
                .appendingPathComponent(sessionID, isDirectory: true)
            try? FileManager.default.removeItem(at: dir)
        }
        // Also sweep projects for the transcript folder when the slug drifted.
        let projects = (try? FileManager.default.contentsOfDirectory(
            at: projectsDirectory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )) ?? []
        for project in projects {
            let dir = project
                .appendingPathComponent("agent-transcripts", isDirectory: true)
                .appendingPathComponent(sessionID, isDirectory: true)
            try? FileManager.default.removeItem(at: dir)
        }
    }

    // MARK: - Helpers

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

    static func flattenText(_ content: Any?) -> [String] {
        if let text = content as? String { return [text] }
        guard let blocks = content as? [[String: Any]] else { return [] }
        return blocks.compactMap { block in
            guard (block["type"] as? String) == "text" else { return nil }
            return block["text"] as? String
        }
    }

    /// Cursor wraps user turns in `<user_query>` and often a `<timestamp>`.
    static func stripHarnessWrappers(_ text: String) -> String {
        var result = text
        if let start = result.range(of: "<user_query>"),
           let end = result.range(of: "</user_query>") {
            result = String(result[start.upperBound..<end.lowerBound])
        }
        if let ts = result.range(of: #"<timestamp>.*?</timestamp>"#, options: .regularExpression) {
            result.removeSubrange(ts)
        }
        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func wrapUserQuery(_ text: String) -> String {
        "<user_query>\n\(text)\n</user_query>"
    }

    static func encodeJSONL(role: String, text: String) -> String {
        let record: [String: Any] = [
            "role": role,
            "message": [
                "content": [["type": "text", "text": text]]
            ]
        ]
        guard JSONSerialization.isValidJSONObject(record),
              let data = try? JSONSerialization.data(withJSONObject: record),
              let line = String(data: data, encoding: .utf8)
        else { return "{\"role\":\"\(role)\",\"message\":{\"content\":[]}}" }
        return line
    }

    /// Formats canonical entries as a handoff preamble for `agent --print` seeding.
    public static func handoffPrompt(from entries: [CanonicalEntry]) -> String {
        var lines: [String] = [
            "[Handoff] Prior conversation for continuity. Treat this as already exchanged:",
            ""
        ]
        for entry in entries {
            switch entry {
            case let .userMessage(text, _):
                lines.append("User: \(text)")
            case let .assistantMessage(text, _):
                lines.append("Assistant: \(text)")
            case let .systemNote(text, _):
                lines.append("Note: \(text)")
            case let .handoffMarker(from, to, reason, _):
                lines.append("Note: Handed off from \(from.displayName) to \(to.displayName): \(reason)")
            default:
                continue
            }
        }
        lines.append("")
        lines.append("Reply with only: ACK")
        return lines.joined(separator: "\n")
    }

    /// How a Cursor store-seed invocation carries the handoff preamble.
    ///
    /// `agent --print` only accepts the prompt as a positional argv element.
    /// Past a few hundred KB that trips the kernel's `E2BIG` ("Argument list
    /// too long") and the whole handoff fails before Cursor ever starts. Small
    /// conversations stay inline; larger ones are written to a file and the
    /// argv prompt only points at that path so Cursor can Read it.
    public enum StoreSeedPayload: Equatable, Sendable {
        case inline(prompt: String)
        case fileBacked(promptFile: URL, launchPrompt: String)
    }

    /// Conservative ceiling for an inline argv prompt. macOS `ARG_MAX` is
    /// shared with the environment and is typically 256 KB–1 MB; staying well
    /// under that leaves room for Cursor's own flags and inherited env.
    public static let maxInlinePromptUTF8Bytes = 128_000

    /// Builds the seed payload, writing `promptFile` only when the full
    /// preamble would be unsafe to place on argv.
    public static func storeSeedPayload(
        from entries: [CanonicalEntry],
        promptFile: URL
    ) throws -> StoreSeedPayload {
        let prompt = handoffPrompt(from: entries)
        if prompt.utf8.count <= maxInlinePromptUTF8Bytes {
            return .inline(prompt: prompt)
        }
        try prompt.write(to: promptFile, atomically: true, encoding: .utf8)
        return .fileBacked(
            promptFile: promptFile,
            launchPrompt: fileBackedLaunchPrompt(pointingTo: promptFile)
        )
    }

    /// Short argv prompt used when the full preamble lives on disk.
    public static func fileBackedLaunchPrompt(pointingTo url: URL) -> String {
        """
        [Handoff] Prior conversation for continuity is in the file at the absolute path below.
        Read that file once with the Read tool. Treat its entire contents as already exchanged.
        Do not edit the file. Do not use other tools. Reply with only: ACK

        \(url.path)
        """
    }
}

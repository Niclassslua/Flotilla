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
        var synthesizedToolID = 0
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

            // Cursor's display JSONL stores tool *calls* but never results, and
            // never inlines image bytes. Screenshots show up as a `Read` of an
            // image path and/or a markdown `![](/absolute/path.png)` in the
            // assistant reply — load those files the same way Claude's
            // `SendUserFile` and Codex's `ImageView` paths are handled.
            if let blocks = content as? [[String: Any]] {
                var texts: [String] = []
                var recordEntries: [CanonicalEntry] = []
                for block in blocks {
                    switch block["type"] as? String {
                    case "text":
                        guard let raw = block["text"] as? String else { continue }
                        texts.append(raw)
                    case "tool_use":
                        guard let name = block["name"] as? String else { continue }
                        let input = block["input"] as? [String: Any] ?? [:]
                        synthesizedToolID += 1
                        let id = (block["id"] as? String).flatMap { $0.isEmpty ? nil : $0 }
                            ?? "cursor-tool-\(synthesizedToolID)"
                        recordEntries.append(.toolUse(
                            id: id,
                            tool: name,
                            input: Self.encodeJSON(input),
                            timestamp: stamp
                        ))
                        // Screenshots are a Read of an image path — keep the
                        // inline image entry when the file is loadable.
                        if let path = Self.imagePath(fromToolInput: input),
                           let image = Self.imageEntry(atPath: path, timestamp: stamp) {
                            recordEntries.append(image)
                        }
                    default:
                        continue
                    }
                }
                if let role {
                    let text = texts
                        .map(Self.stripHarnessWrappers)
                        // Some models' end-of-sequence token leaks into the reply.
                        .map { $0.replacingOccurrences(of: "<|eos|>", with: "").trimmingCharacters(in: .whitespacesAndNewlines) }
                        .filter { !$0.isEmpty && $0 != "[REDACTED]" }
                        .joined(separator: "\n")
                    if !text.isEmpty {
                        switch role {
                        case "user":
                            entries.append(.userMessage(text: text, timestamp: stamp))
                        case "assistant":
                            entries.append(.assistantMessage(text: text, timestamp: stamp))
                        default:
                            break
                        }
                    }
                    if role == "assistant" || role == "user" {
                        for raw in texts {
                            for path in Self.markdownImagePaths(in: raw) {
                                if let image = Self.imageEntry(atPath: path, timestamp: stamp) {
                                    recordEntries.append(image)
                                }
                            }
                        }
                    }
                }
                entries.append(contentsOf: recordEntries)
                continue
            }

            let texts = Self.flattenText(content)
            guard let role, !texts.isEmpty else { continue }
            let text = texts
                .map(Self.stripHarnessWrappers)
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
        return Self.dedupingImages(entries)
    }

    public func discoverSession(workingDirectory: URL, since: Date) throws -> (sessionID: String, url: URL)? {
        let bucket = chatsDirectory.appendingPathComponent(
            Self.chatBucketHash(for: workingDirectory.path),
            isDirectory: true
        )
        guard FileManager.default.fileExists(atPath: bucket.path) else { return nil }
        let dirs = (try? FileManager.default.contentsOfDirectory(
            at: bucket,
            includingPropertiesForKeys: [.creationDateKey, .contentModificationDateKey],
            options: [.skipsHiddenFiles]
        )) ?? []

        // Earliest creation at/after launch — not latest updatedAt/mtime
        // (docs/session-handoff.md). Recency picks the wrong chat when an
        // older conversation in the same cwd was touched after launch.
        var candidates: [(id: String, url: URL, created: Date)] = []
        for dir in dirs {
            let metaURL = dir.appendingPathComponent("meta.json")
            guard let data = try? Data(contentsOf: metaURL),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }
            let createdMs = json["createdAtMs"] as? Double
            let values = try? dir.resourceValues(forKeys: [.creationDateKey, .contentModificationDateKey])
            let created = createdMs.map { Date(timeIntervalSince1970: $0 / 1000) }
                ?? values?.creationDate
                ?? values?.contentModificationDate
                ?? .distantPast
            guard created >= since else { continue }
            let id = dir.lastPathComponent
            let url = (try? transcriptURL(sessionID: id, workingDirectory: workingDirectory)) ?? metaURL
            candidates.append((id, url, created))
        }
        return candidates.min(by: { $0.created < $1.created }).map { ($0.id, $0.url) }
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

    private static let imageExtensions: Set<String> = [
        "png", "jpg", "jpeg", "gif", "webp", "bmp", "tiff", "heic"
    ]

    private static func isImagePath(_ path: String) -> Bool {
        let ext = (path as NSString).pathExtension.lowercased()
        return imageExtensions.contains(ext)
    }

    /// Absolute (or `file://`) image paths from a tool call's scalar inputs.
    private static func imagePath(fromToolInput input: [String: Any]) -> String? {
        let candidates = [
            input["path"] as? String,
            input["file_path"] as? String,
            input["filePath"] as? String,
            input["url"] as? String
        ].compactMap { $0 }
        return candidates.first { isImagePath($0) }
    }

    /// `![alt](/abs/path.png)` links Cursor agents use when presenting a
    /// screenshot. Remote `http(s)` URLs are ignored — only on-disk files can
    /// be downsampled for the companion wire.
    private static func markdownImagePaths(in text: String) -> [String] {
        guard text.contains("![") else { return [] }
        let pattern = #"!\[(?:[^\]]*)\]\(([^)\s]+)(?:\s+\"[^\"]*\")?\)"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let ns = text as NSString
        let matches = regex.matches(in: text, range: NSRange(location: 0, length: ns.length))
        return matches.compactMap { match -> String? in
            guard match.numberOfRanges > 1,
                  let range = Range(match.range(at: 1), in: text)
            else { return nil }
            var path = String(text[range])
            if path.hasPrefix("<"), path.hasSuffix(">") {
                path = String(path.dropFirst().dropLast())
            }
            if path.hasPrefix("http://") || path.hasPrefix("https://") { return nil }
            guard isImagePath(path) else { return nil }
            return path
        }
    }

    private static func imageEntry(atPath rawPath: String, timestamp: Date) -> CanonicalEntry? {
        let url: URL?
        if rawPath.hasPrefix("file://") {
            url = URL(string: rawPath)
        } else if rawPath.hasPrefix("~/") {
            url = URL(fileURLWithPath: (rawPath as NSString).expandingTildeInPath)
        } else {
            url = URL(fileURLWithPath: rawPath)
        }
        guard let url, let downsampled = ImageDownsampler.downsample(at: url) else { return nil }
        return .image(
            mimeType: downsampled.mimeType,
            base64: downsampled.base64,
            // Keep the absolute path so the screenshot panel's path heuristics
            // (Desktop /tmp dump folders) still see it when there is no
            // paired toolUse on the same record (markdown-only delivery).
            filename: url.path,
            timestamp: timestamp
        )
    }

    /// A screenshot the agent takes commonly reaches the transcript twice:
    /// once when `Read` names the path, and again when the reply embeds the
    /// same (or a copied) file as markdown. Both downsample deterministically,
    /// so identical source bytes collapse to one `.image`.
    private static func dedupingImages(_ entries: [CanonicalEntry]) -> [CanonicalEntry] {
        var seen = Set<String>()
        return entries.filter { entry in
            guard case let .image(_, base64, _, _) = entry else { return true }
            return seen.insert(base64).inserted
        }
    }

    private static func encodeJSON(_ value: Any) -> Data {
        guard JSONSerialization.isValidJSONObject(value),
              let data = try? JSONSerialization.data(withJSONObject: value)
        else { return Data("{}".utf8) }
        return data
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

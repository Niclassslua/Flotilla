import Foundation
import SessionKit

/// Reads Antigravity's conversation log under `~/.gemini/antigravity-cli/brain`.
///
/// **Source only, and permanently so.** The file this reads —
/// `brain/<id>/.system_generated/logs/transcript.jsonl` — is a *log*, not the
/// state Antigravity resumes from. Its real state is one SQLite database per
/// conversation (`conversations/<id>.db`, table `steps`) whose every payload is
/// an opaque protobuf blob with no published schema. Synthesising one would
/// mean reverse-engineering wire format field by field, and it would break
/// silently on each release.
///
/// So a session can be moved *out* of Antigravity and never into it. That is
/// expressed by conforming to ``TranscriptReading`` alone: the registry then
/// reports Antigravity as a source and never as a destination, with no rule
/// written anywhere that anyone has to remember.
public struct AntigravityTranscriptCodec: TranscriptReading {
    public let agent: AgentKind = .antigravity

    private let brainDirectory: URL

    public init(
        brainDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".gemini/antigravity-cli/brain", isDirectory: true)
    ) {
        self.brainDirectory = brainDirectory
    }

    // MARK: - TranscriptReading

    public func transcriptURL(sessionID: String, workingDirectory: URL) throws -> URL? {
        let file = brainDirectory
            .appendingPathComponent(sessionID, isDirectory: true)
            .appendingPathComponent(".system_generated/logs/transcript.jsonl")
        return FileManager.default.fileExists(atPath: file.path) ? file : nil
    }

    /// The log records no identity of its own — the conversation id is the
    /// directory it sits in. Returning `nil` says "cannot verify" rather than
    /// asserting a match, which is the honest answer.
    public func embeddedSessionID(at url: URL) throws -> String? {
        nil
    }

    public func readNative(at url: URL) throws -> [CanonicalEntry] {
        let contents = try String(contentsOf: url, encoding: .utf8)

        return contents.split(separator: "\n", omittingEmptySubsequences: true).compactMap { line in
            guard let data = line.data(using: .utf8),
                  let record = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let content = record["content"] as? String
            else { return nil }

            let text = Self.unwrap(content)
            guard !text.isEmpty else { return nil }

            let timestamp = Self.parseTimestamp(record["created_at"] as? String)

            // Antigravity labels each step by who produced it. Tool activity is
            // not distinguished from prose here — it arrives as `GENERIC` model
            // text — so this codec carries the conversation, not the tool call
            // structure. That is a real limit of the log, not a shortcut.
            switch record["source"] as? String {
            case "USER_EXPLICIT":
                return .userMessage(text: text, timestamp: timestamp)
            case "MODEL":
                return .assistantMessage(text: text, timestamp: timestamp)
            case "SYSTEM":
                return .systemNote(text: text, timestamp: timestamp)
            default:
                return nil
            }
        }
    }

    /// User steps arrive wrapped in a `<USER_REQUEST>` element. The next agent
    /// should read the request, not Antigravity's framing of it.
    static func unwrap(_ content: String) -> String {
        var text = content.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.hasPrefix("<USER_REQUEST>") {
            text = String(text.dropFirst("<USER_REQUEST>".count))
            if let range = text.range(of: "</USER_REQUEST>", options: .backwards) {
                text = String(text[text.startIndex..<range.lowerBound])
            }
        }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static let fractionalStyle = Date.ISO8601FormatStyle(includingFractionalSeconds: true)
    private static let plainStyle = Date.ISO8601FormatStyle()

    static func parseTimestamp(_ raw: String?) -> Date {
        guard let raw else { return Date() }
        if let date = try? plainStyle.parse(raw) { return date }
        if let date = try? fractionalStyle.parse(raw) { return date }
        return Date()
    }
}

extension AntigravityTranscriptCodec {
    /// Antigravity records a conversation in `conversation_summaries.db` only
    /// once it has titled it, and writes no workspace into the log at all. A
    /// live session is therefore invisible to title or working-directory
    /// matching, sometimes for minutes.
    ///
    /// The directory is the evidence: `brain/<conversation id>/` is created
    /// when the agent starts. So the conversation to associate with a session
    /// is the **earliest** one created at or after that session launched —
    /// anything created before belongs to an earlier session, and anything
    /// created later belongs to a later one.
    ///
    /// Creation time, not modification time. A conversation created weeks ago
    /// can be modified today, so "most recently modified since launch" happily
    /// resolves to somebody else's long-running conversation; "first created
    /// after launch" cannot.
    public func discoverSession(workingDirectory: URL, since: Date) throws -> (sessionID: String, url: URL)? {
        let candidates = (try? FileManager.default.contentsOfDirectory(
            at: brainDirectory,
            includingPropertiesForKeys: [.creationDateKey],
            options: [.skipsHiddenFiles]
        )) ?? []

        let started: [(id: String, url: URL, created: Date)] = candidates.compactMap { directory in
            let transcript = directory
                .appendingPathComponent(".system_generated/logs/transcript.jsonl")
            guard FileManager.default.fileExists(atPath: transcript.path) else { return nil }
            guard let created = try? directory.resourceValues(forKeys: [.creationDateKey]).creationDate,
                  created >= since
            else { return nil }
            return (directory.lastPathComponent, transcript, created)
        }

        // Earliest, not latest — see the note above.
        for candidate in started.sorted(by: { $0.created < $1.created }) {
            guard let entries = try? readNative(at: candidate.url),
                  entries.hasConversationalContent
            else { continue }
            return (candidate.id, candidate.url)
        }
        return nil
    }
}

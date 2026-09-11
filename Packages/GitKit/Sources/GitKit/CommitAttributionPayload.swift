import Foundation

/// How the attribution hooks behave for one session. Mirrors the app's
/// setting as its own type so GitKit stays free of SettingsKit.
public enum CommitAttributionHookMode: String, Codable, Sendable {
    case off
    case local
    case shared
}

/// The session facts the app hands to the hooks and reads back when it
/// ingests their events. The agent is a raw value so GitKit stays free of
/// SessionKit.
public struct CommitAttributionSessionInfo: Codable, Equatable, Sendable {
    public var sessionID: UUID
    public var projectID: UUID?
    public var agent: String
    /// The model picked at launch; `nil` means the agent's own default.
    public var model: String?
    public var title: String
    public var prompt: String
    public var createdAt: Date

    public init(
        sessionID: UUID,
        projectID: UUID?,
        agent: String,
        model: String?,
        title: String,
        prompt: String,
        createdAt: Date
    ) {
        self.sessionID = sessionID
        self.projectID = projectID
        self.agent = agent
        self.model = model
        self.title = title
        self.prompt = prompt
        self.createdAt = createdAt
    }
}

/// The per-session directory the attribution hooks read and write:
///
/// - `mode`, `agent`, `model`: one value each, read by the hooks at commit time
/// - `prompt.md`: the document Shared mode commits into the repository
/// - `session.json`: what the app needs to ingest events, even after the
///   session itself was deleted
/// - `events.jsonl`: the spool Local mode appends to
public enum CommitAttributionPayload {
    public static let modeFileName = "mode"
    public static let agentFileName = "agent"
    public static let modelFileName = "model"
    public static let promptFileName = "prompt.md"
    public static let sessionFileName = "session.json"
    public static let eventsFileName = "events.jsonl"

    /// Writes everything the hooks read. Each file is replaced atomically, so
    /// a hook reading mid-write sees the old value or the new one, never half.
    public static func write(
        _ info: CommitAttributionSessionInfo,
        mode: CommitAttributionHookMode,
        to directory: URL
    ) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try writeMode(.off, to: directory)
        guard mode != .off else { return }
        try Data(info.agent.utf8)
            .write(to: directory.appendingPathComponent(agentFileName), options: .atomic)
        try Data((info.model ?? "default").utf8)
            .write(to: directory.appendingPathComponent(modelFileName), options: .atomic)
        try Data(CommitAttributionPromptDocument.render(info).utf8)
            .write(to: directory.appendingPathComponent(promptFileName), options: .atomic)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(info)
            .write(to: directory.appendingPathComponent(sessionFileName), options: .atomic)
        try writeMode(mode, to: directory)
    }

    public static func writeMode(_ mode: CommitAttributionHookMode, to directory: URL) throws {
        try Data(mode.rawValue.utf8)
            .write(to: directory.appendingPathComponent(modeFileName), options: .atomic)
    }

    public static func readSessionInfo(in directory: URL) -> CommitAttributionSessionInfo? {
        guard let data = try? Data(contentsOf: directory.appendingPathComponent(sessionFileName)) else {
            return nil
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(CommitAttributionSessionInfo.self, from: data)
    }

    /// Reads atomically published event files. Writers publish only after
    /// closing the file, so ingestion never deletes an in-flight append.
    public static func claimEvents(in directory: URL) -> CommitAttributionEventClaim {
        let fileManager = FileManager.default
        let files = ((try? fileManager.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.pathExtension == "ready" || $0.pathExtension == "claimed" }
            .sorted {
                let left = (try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                let right = (try? $1.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                return left == right ? $0.lastPathComponent < $1.lastPathComponent : left < right
            }
        var events: [CommitAttributionEvent] = []
        for file in files {
            guard let data = try? Data(contentsOf: file) else { continue }
            for line in String(decoding: data, as: UTF8.self).split(separator: "\n") {
                if let event = CommitAttributionEvent(line: String(line)) {
                    events.append(event)
                }
            }
        }
        events.sort { left, right in
            func order(_ event: CommitAttributionEvent) -> (Date, Int) {
                switch event {
                case .commit(let value): return (value.recordedAt, 0)
                case .rewrite(let value): return (value.recordedAt, 1)
                }
            }
            return order(left) < order(right)
        }
        return CommitAttributionEventClaim(events: events, files: files)
    }
}

/// Events taken from a session's spool, deleted only once stored.
public struct CommitAttributionEventClaim: Sendable {
    public let events: [CommitAttributionEvent]
    let files: [URL]

    /// Deletes the claimed spool files. Call after the events are persisted.
    public func complete() {
        for file in files {
            try? FileManager.default.removeItem(at: file)
        }
    }
}

/// One line of a session's spool, as written by the attribution hooks.
public enum CommitAttributionEvent: Equatable, Sendable {
    case commit(Commit)
    case rewrite(Rewrite)

    public struct Commit: Equatable, Sendable {
        public var sha: String
        public var authorEmail: String
        /// Seconds since 1970, as Git records the author time.
        public var authorTime: Int
        /// The repository's shared git directory with symlinks resolved.
        public var commonDirectory: String
        public var agent: String
        public var model: String?
        public var sessionInfo: CommitAttributionSessionInfo?
        public var recordedAt: Date
    }

    public struct Rewrite: Equatable, Sendable {
        public struct Pair: Equatable, Sendable {
            public var old: String
            public var new: String
        }

        /// `amend` or `rebase`, as git passes it to `post-rewrite`.
        public var kind: String
        /// The repository's shared git directory with symlinks resolved.
        public var commonDirectory: String
        public var pairs: [Pair]
        public var recordedAt: Date
    }

    public init?(line: String) {
        guard let data = line.data(using: .utf8),
              let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let event = object["event"] as? String
        else { return nil }
        let recordedAt = Date(timeIntervalSince1970: (object["recordedAt"] as? NSNumber)?.doubleValue ?? 0)

        switch event {
        case "commit":
            guard let sha = object["sha"] as? String, !sha.isEmpty,
                  let commonDirectory = object["commonDirectory"] as? String, !commonDirectory.isEmpty
            else { return nil }
            let model = (object["model"] as? String).flatMap { $0.isEmpty || $0 == "default" ? nil : $0 }
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            let sessionInfo = (object["session"] as? [String: Any]).flatMap {
                try? JSONSerialization.data(withJSONObject: $0)
            }.flatMap { try? decoder.decode(CommitAttributionSessionInfo.self, from: $0) }
            self = .commit(Commit(
                sha: sha,
                authorEmail: object["authorEmail"] as? String ?? "",
                authorTime: (object["authorTime"] as? NSNumber)?.intValue ?? 0,
                commonDirectory: commonDirectory,
                agent: object["agent"] as? String ?? "",
                model: model,
                sessionInfo: sessionInfo,
                recordedAt: recordedAt
            ))
        case "rewrite":
            let pairs = (object["pairs"] as? [[String]] ?? []).compactMap { pair in
                pair.count >= 2 ? Rewrite.Pair(old: pair[0], new: pair[1]) : nil
            }
            guard !pairs.isEmpty,
                  let commonDirectory = object["commonDirectory"] as? String, !commonDirectory.isEmpty
            else { return nil }
            self = .rewrite(Rewrite(
                kind: object["kind"] as? String ?? "",
                commonDirectory: commonDirectory,
                pairs: pairs,
                recordedAt: recordedAt
            ))
        default:
            return nil
        }
    }
}

/// `prompt.md`, the readable half of Shared mode: front matter a reviewer can
/// read in a pull request, then the prompt verbatim.
public enum CommitAttributionPromptDocument {
    public static func render(_ info: CommitAttributionSessionInfo) -> String {
        let lines = [
            "---",
            "session: \(info.sessionID.uuidString)",
            "agent: \(info.agent)",
            "model: \(info.model ?? "default")",
            "created: \(ISO8601DateFormatter().string(from: info.createdAt))",
            "title: \(quoted(info.title))",
            "---",
            "",
            info.prompt,
        ]
        let document = lines.joined(separator: "\n")
        return document + "\n"
    }

    /// The session a committed `prompt.md` describes. The project is not part
    /// of the document, so it is always `nil`.
    public static func parse(_ text: String) -> CommitAttributionSessionInfo? {
        guard text.hasPrefix("---\n") else { return nil }
        let body = text.dropFirst(4)
        guard let end = body.range(of: "\n---\n") else { return nil }

        var fields: [String: String] = [:]
        for line in body[..<end.lowerBound].split(separator: "\n") {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let key = String(line[..<colon])
            fields[key] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }
        guard let sessionID = fields["session"].flatMap(UUID.init(uuidString:)),
              let agent = fields["agent"], !agent.isEmpty
        else { return nil }

        var prompt = String(body[end.upperBound...])
        if prompt.hasPrefix("\n") { prompt.removeFirst() }
        if prompt.hasSuffix("\n") { prompt.removeLast() }
        let model = fields["model"].flatMap { $0.isEmpty || $0 == "default" ? nil : $0 }

        return CommitAttributionSessionInfo(
            sessionID: sessionID,
            projectID: nil,
            agent: agent,
            model: model,
            title: fields["title"].flatMap(unquoted) ?? "",
            prompt: prompt,
            createdAt: fields["created"].flatMap { ISO8601DateFormatter().date(from: $0) } ?? Date(timeIntervalSince1970: 0)
        )
    }

    /// A JSON string literal is also a valid YAML double-quoted scalar.
    private static func quoted(_ value: String) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: value, options: [.fragmentsAllowed]),
              let literal = String(data: data, encoding: .utf8)
        else { return "\"\"" }
        return literal
    }

    private static func unquoted(_ literal: String) -> String? {
        guard let data = literal.data(using: .utf8) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])) as? String
    }
}

/// One marker path: `.flotilla/sessions/<session>/m-<id>.<agent>.<model>`.
public struct CommitAttributionMarker: Equatable, Sendable {
    public var sessionID: UUID
    public var agent: String
    /// The model as the hooks spelled it in the file name — see `slug(_:)`.
    public var modelSlug: String

    public init?(path: String) {
        let components = path.split(separator: "/").map(String.init)
        guard components.count == 4,
              "\(components[0])/\(components[1])" == CommitAttributionHooks.sharedDirectory,
              let sessionID = UUID(uuidString: components[2]),
              components[3].hasPrefix("m-")
        else { return nil }
        let parts = components[3].dropFirst(2).split(separator: ".", maxSplits: 2, omittingEmptySubsequences: false)
        guard parts.count == 3, !parts[0].isEmpty, !parts[1].isEmpty, !parts[2].isEmpty else { return nil }
        self.sessionID = sessionID
        self.agent = String(parts[1])
        self.modelSlug = String(parts[2])
    }

    /// Where a session's `prompt.md` lives in the repository.
    public static func promptDocumentPath(for sessionID: UUID) -> String {
        "\(CommitAttributionHooks.sharedDirectory)/\(sessionID.uuidString)/\(CommitAttributionPayload.promptFileName)"
    }

    /// The hooks' file-name spelling of a value: anything outside
    /// `A-Za-z0-9._-` becomes `-`, capped at 64 characters.
    public static func slug(_ value: String) -> String {
        let allowed = Set("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789._-")
        return String(String(value.map { allowed.contains($0) ? $0 : "-" }).prefix(64))
    }
}

/// What Git keeps unchanged when a commit is rebased, cherry-picked or amended.
public struct GitCommitIdentity: Hashable, Sendable {
    public var sha: String
    public var authorEmail: String
    public var authorTime: Int

    public init(sha: String, authorEmail: String, authorTime: Int) {
        self.sha = sha
        self.authorEmail = authorEmail
        self.authorTime = authorTime
    }
}

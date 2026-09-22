import CryptoKit
import Foundation
import SessionKit

/// Discovers Cursor Agent CLI chats under `~/.cursor/chats/<md5(cwd)>/<id>/`.
public struct CursorSessionProvider: AgentSessionProviding {
    public let agent: AgentKind = .cursorAgent
    public let cursorHomeURL: URL

    public init(cursorHomeURL: URL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".cursor")) {
        self.cursorHomeURL = cursorHomeURL
    }

    public func fetchSessions() async throws -> [DiscoveredAgentSession] {
        let chatsURL = cursorHomeURL.appendingPathComponent("chats")
        guard FileManager.default.fileExists(atPath: chatsURL.path) else { return [] }

        let buckets = (try? FileManager.default.contentsOfDirectory(
            at: chatsURL,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )) ?? []

        var sessions: [DiscoveredAgentSession] = []
        for bucket in buckets {
            let chatDirs = (try? FileManager.default.contentsOfDirectory(
                at: bucket,
                includingPropertiesForKeys: [.contentModificationDateKey],
                options: [.skipsHiddenFiles]
            )) ?? []
            for chatDir in chatDirs {
                if let session = parseChatDirectory(chatDir) {
                    sessions.append(session)
                }
            }
        }
        return sessions.sorted { ($0.lastActiveAt ?? .distantPast) > ($1.lastActiveAt ?? .distantPast) }
    }

    public func fetchLatestSession(for workingDirectory: URL, since: Date? = nil) async throws -> DiscoveredAgentSession? {
        let cwd = workingDirectory.resolvingSymlinksInPath().path
        let bucket = cursorHomeURL
            .appendingPathComponent("chats")
            .appendingPathComponent(Self.chatBucketHash(for: cwd))
        guard FileManager.default.fileExists(atPath: bucket.path) else { return nil }

        let chatDirs = (try? FileManager.default.contentsOfDirectory(
            at: bucket,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        )) ?? []

        let sorted = chatDirs.sorted { a, b in
            let dateA = (try? a.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            let dateB = (try? b.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            return dateA > dateB
        }

        for dir in sorted {
            guard let session = parseChatDirectory(dir, overrideWorkingDirectory: workingDirectory) else { continue }
            if let since {
                if (session.lastActiveAt ?? .distantPast) >= since { return session }
            } else {
                return session
            }
        }
        return nil
    }

    /// Chat parent directories are `md5(realpath(cwd))` hex digests.
    public static func chatBucketHash(for cwdPath: String) -> String {
        let data = Data(cwdPath.utf8)
        return Insecure.MD5.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    public static func transcriptURL(home: URL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".cursor"), chatID: String, cwd: URL) -> URL? {
        let projects = home.appendingPathComponent("projects")
        let slugCandidates = projectSlugCandidates(for: cwd)
        for slug in slugCandidates {
            let url = projects
                .appendingPathComponent(slug)
                .appendingPathComponent("agent-transcripts")
                .appendingPathComponent(chatID)
                .appendingPathComponent("\(chatID).jsonl")
            if FileManager.default.fileExists(atPath: url.path) { return url }
        }
        // Scan projects for the transcript folder when the slug algorithm drifts.
        let projectDirs = (try? FileManager.default.contentsOfDirectory(at: projects, includingPropertiesForKeys: nil)) ?? []
        for project in projectDirs {
            let url = project
                .appendingPathComponent("agent-transcripts")
                .appendingPathComponent(chatID)
                .appendingPathComponent("\(chatID).jsonl")
            if FileManager.default.fileExists(atPath: url.path) { return url }
        }
        return nil
    }

    private static func projectSlugCandidates(for cwd: URL) -> [String] {
        let path = cwd.resolvingSymlinksInPath().path
        let withoutPrivate = path.replacingOccurrences(of: "/private", with: "", options: [.anchored])
        return [
            path.replacingOccurrences(of: "/", with: "-").trimmingCharacters(in: CharacterSet(charactersIn: "-")),
            withoutPrivate.replacingOccurrences(of: "/", with: "-").trimmingCharacters(in: CharacterSet(charactersIn: "-")),
            "private" + path.replacingOccurrences(of: "/", with: "-"),
        ]
    }

    private func parseChatDirectory(_ chatDir: URL, overrideWorkingDirectory: URL? = nil) -> DiscoveredAgentSession? {
        let metaURL = chatDir.appendingPathComponent("meta.json")
        guard let data = try? Data(contentsOf: metaURL),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        let id = chatDir.lastPathComponent
        let title = (json["title"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        let cwdString = json["cwd"] as? String
        let workingDirectory = overrideWorkingDirectory
            ?? cwdString.map { URL(fileURLWithPath: $0) }
        let updatedMs = json["updatedAtMs"] as? Double
        let createdMs = json["createdAtMs"] as? Double
        let lastActive: Date?
        if let updatedMs {
            lastActive = Date(timeIntervalSince1970: updatedMs / 1000)
        } else if let createdMs {
            lastActive = Date(timeIntervalSince1970: createdMs / 1000)
        } else {
            lastActive = try? chatDir.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
        }
        let resolvedTitle = (title?.isEmpty == false ? title : nil) ?? "Cursor chat"
        let createdAt: Date? = createdMs.map { Date(timeIntervalSince1970: $0 / 1000) }
        return DiscoveredAgentSession(
            id: id,
            title: resolvedTitle,
            workingDirectory: workingDirectory,
            createdAt: createdAt,
            lastActiveAt: lastActive,
            agent: .cursorAgent,
            isCustomTitle: title?.isEmpty == false
        )
    }
}

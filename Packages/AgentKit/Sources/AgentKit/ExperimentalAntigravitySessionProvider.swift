import Foundation
import SessionKit
import SQLite3

/// Discovers sessions managed by Antigravity (`agy`) by inspecting conversation logs
/// under `~/.gemini/antigravity-cli/brain/` and `~/.gemini/antigravity-cli/conversation_summaries.db`.
public struct ExperimentalAntigravitySessionProvider: AgentSessionProviding {
    public let agent: AgentKind = .antigravity
    public let brainURL: URL

    public init(
        brainURL: URL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".gemini/antigravity-cli/brain")
    ) {
        self.brainURL = brainURL
    }

    public func fetchSessions() async throws -> [DiscoveredAgentSession] {
        try await fetchSessions(since: nil)
    }

    public func fetchLatestSession(for workingDirectory: URL, since: Date? = nil) async throws -> DiscoveredAgentSession? {
        let sessions = try await fetchSessions(since: since, limit: 10)
        let target = workingDirectory.standardizedFileURL.path
        let isGeneralSession = target.contains(".flotilla/general-session") || target.hasSuffix("/general-session")

        return sessions.first { session in
            let matchesPath: Bool
            if let dir = session.workingDirectory?.standardizedFileURL.path {
                matchesPath = (dir == target || target.hasPrefix(dir) || dir.hasPrefix(target))
            } else {
                // If Antigravity transcript has no explicit workspace argument, match if Flotilla is running a general session
                matchesPath = isGeneralSession
            }
            guard matchesPath else { return false }

            if let since {
                return (session.lastActiveAt ?? .distantPast) >= since
            }
            return true
        }
    }

    private func fetchSessions(since: Date?, limit: Int? = nil) async throws -> [DiscoveredAgentSession] {
        guard FileManager.default.fileExists(atPath: brainURL.path) else { return [] }

        // 1. Read conversation_summaries.db for workspace mappings and titles
        let dbSummaries = fetchSummariesFromDatabase()

        let conversationFolders = (try? FileManager.default.contentsOfDirectory(
            at: brainURL,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        )) ?? []

        let threshold = since?.addingTimeInterval(-60)
        var foldersWithDates: [(url: URL, date: Date)] = []
        for folder in conversationFolders {
            let sessionID = folder.lastPathComponent
            let date = (try? folder.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate)
                ?? dbSummaries[sessionID]?.date
                ?? .distantPast
            if let threshold, date < threshold {
                continue
            }
            foldersWithDates.append((folder, date))
        }

        foldersWithDates.sort { $0.date > $1.date }

        var sessions: [DiscoveredAgentSession] = []

        for (folder, folderDate) in foldersWithDates {
            let sessionID = folder.lastPathComponent
            let logFile = folder.appendingPathComponent(".system_generated/logs/transcript.jsonl")
            guard FileManager.default.fileExists(atPath: logFile.path) else { continue }

            let date = (try? logFile.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate)
                ?? (folderDate != .distantPast ? folderDate : dbSummaries[sessionID]?.date)

            if let threshold, let date, date < threshold {
                continue
            }

            let dbInfo = dbSummaries[sessionID]
            let resolvedTitle = (extractTitleFromTranscript(logFile) ?? dbInfo?.title)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard let title = resolvedTitle, !title.isEmpty, !title.contains("\n"), title.count <= 120 else { continue }

            let resolvedCwd = dbInfo?.cwd ?? extractWorkspaceFromTranscript(logFile)

            sessions.append(DiscoveredAgentSession(
                id: sessionID,
                title: title,
                workingDirectory: resolvedCwd,
                lastActiveAt: date,
                agent: .antigravity,
                isCustomTitle: true
            ))

            if let limit, sessions.count >= limit {
                break
            }
        }

        return sessions.sorted { ($0.lastActiveAt ?? .distantPast) > ($1.lastActiveAt ?? .distantPast) }
    }

    private func fetchSummariesFromDatabase() -> [String: (title: String?, cwd: URL?, date: Date?)] {
        let dbURL = brainURL.deletingLastPathComponent().appendingPathComponent("conversation_summaries.db")
        guard FileManager.default.fileExists(atPath: dbURL.path) else { return [:] }

        var db: OpaquePointer?
        guard sqlite3_open_v2(dbURL.path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK, let db else {
            return [:]
        }
        defer { sqlite3_close(db) }

        let query = "SELECT conversation_id, title, workspace_uris, last_modified_time FROM conversation_summaries;"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, query, -1, &stmt, nil) == SQLITE_OK, let stmt else {
            return [:]
        }
        defer { sqlite3_finalize(stmt) }

        var map: [String: (title: String?, cwd: URL?, date: Date?)] = [:]
        let isoFormatter = ISO8601DateFormatter()

        while sqlite3_step(stmt) == SQLITE_ROW {
            guard let idCStr = sqlite3_column_text(stmt, 0) else { continue }
            let id = String(cString: idCStr)

            var title: String?
            if let titleCStr = sqlite3_column_text(stmt, 1) {
                let str = String(cString: titleCStr).trimmingCharacters(in: .whitespacesAndNewlines)
                if !str.isEmpty { title = str }
            }

            var cwd: URL?
            if let wsCStr = sqlite3_column_text(stmt, 2) {
                let wsStr = String(cString: wsCStr)
                if let data = wsStr.data(using: .utf8),
                   let uris = try? JSONSerialization.jsonObject(with: data) as? [String],
                   let firstURI = uris.first {
                    if firstURI.hasPrefix("file://") {
                        cwd = URL(string: firstURI)
                    } else if firstURI.hasPrefix("/") {
                        cwd = URL(fileURLWithPath: firstURI)
                    }
                }
            }

            var date: Date?
            if let dateCStr = sqlite3_column_text(stmt, 3) {
                let dateStr = String(cString: dateCStr)
                date = isoFormatter.date(from: dateStr)
            }

            map[id] = (title: title, cwd: cwd, date: date)
        }

        return map
    }

    private func extractTitleFromTranscript(_ fileURL: URL) -> String? {
        guard let data = try? Data(contentsOf: fileURL),
              let text = String(data: data, encoding: .utf8) else { return nil }

        guard text.contains("USER Objective:") else { return nil }

        for line in text.split(separator: "\n") {
            guard line.contains("USER Objective:") else { continue }
            let normalized = line.replacingOccurrences(of: "\\n", with: "\n")
                .replacingOccurrences(of: "\\r", with: "")

            // Strictly check for checkpoint objective - Antigravity's official AI-generated title
            if let range = normalized.range(of: "USER Objective:") {
                let after = normalized[range.upperBound...].trimmingCharacters(in: .whitespacesAndNewlines)
                if let firstLine = after.components(separatedBy: .newlines).first, !firstLine.isEmpty {
                    let candidate = String(firstLine).trimmingCharacters(in: .whitespacesAndNewlines)
                    if !candidate.isEmpty && !candidate.contains("\n") && candidate.count <= 100 {
                        return candidate
                    }
                }
            }
        }

        // Return nil until Antigravity synthesizes the objective, preventing prompt flicker
        return nil
    }

    private func extractWorkspaceFromTranscript(_ fileURL: URL) -> URL? {
        guard let data = try? Data(contentsOf: fileURL),
              let text = String(data: data, encoding: .utf8) else { return nil }

        for line in text.split(separator: "\n").prefix(35) {
            if line.contains(" -> /") {
                let parts = line.components(separatedBy: " -> ")
                if parts.count >= 2, let lastPart = parts.last?.components(separatedBy: "\n").first?.components(separatedBy: "\\n").first {
                    let candidate = lastPart.trimmingCharacters(in: .whitespacesAndNewlines)
                    if candidate.hasPrefix("/") {
                        return URL(fileURLWithPath: candidate)
                    }
                }
            }
            if line.contains("\"Cwd\":"),
               let range = line.range(of: "\"Cwd\":") {
                let after = line[range.upperBound...].trimmingCharacters(in: .whitespacesAndNewlines)
                if let startQuote = after.firstIndex(of: "\"") {
                    let afterStart = after[after.index(after: startQuote)...]
                    if let endQuote = afterStart.firstIndex(of: "\"") {
                        let path = String(afterStart[..<endQuote]).replacingOccurrences(of: "\\/", with: "/")
                        if path.hasPrefix("/") {
                            return URL(fileURLWithPath: path)
                        }
                    }
                }
            }
        }

        return nil
    }
}

import Foundation
import SessionKit
import SQLite3

/// Discovers sessions managed by Codex CLI via `~/.codex/session_index.jsonl`
/// and `~/.codex/state_5.sqlite`.
public struct CodexSessionProvider: AgentSessionProviding {
    public let agent: AgentKind = .codexCLI
    public let indexURL: URL
    public let databaseURL: URL

    public init(
        indexURL: URL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".codex/session_index.jsonl"),
        databaseURL: URL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".codex/state_5.sqlite")
    ) {
        self.indexURL = indexURL
        self.databaseURL = databaseURL
    }

    private struct CodexIndexEntry: Decodable {
        let id: String
        let thread_name: String?
        let name: String?
        let title: String?
        let cwd: String?
        let updated_at: String?
    }

    public func fetchSessions() async throws -> [DiscoveredAgentSession] {
        var sessionsByID: [String: DiscoveredAgentSession] = [:]
        var cwdByID: [String: URL] = [:]

        // 1. Read state_5.sqlite for cwd mapping, custom thread names, and prompt titles
        if FileManager.default.fileExists(atPath: databaseURL.path) {
            for (id, session, cwd) in fetchSessionsFromDatabase() {
                if let session {
                    sessionsByID[id] = session
                }
                if let cwd {
                    cwdByID[id] = cwd
                }
            }
        }

        // 2. Overlay session_index.jsonl (append-only, latest thread_name / rename wins)
        if FileManager.default.fileExists(atPath: indexURL.path),
           let data = try? Data(contentsOf: indexURL),
           let text = String(data: data, encoding: .utf8) {

            let decoder = JSONDecoder()
            let isoFormatter = ISO8601DateFormatter()
            isoFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]

            for line in text.split(separator: "\n") {
                let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty,
                      let lineData = trimmed.data(using: .utf8),
                      let entry = try? decoder.decode(CodexIndexEntry.self, from: lineData) else { continue }

                let candidateTitle = entry.thread_name ?? entry.name
                let resolvedTitle: String?
                let isCustom: Bool
                if let raw = candidateTitle?.trimmingCharacters(in: .whitespacesAndNewlines),
                   !raw.isEmpty, !raw.contains("\n"), raw.count <= 100 {
                    resolvedTitle = raw
                    isCustom = true
                } else if let prompt = entry.title, let synthesized = TitleSynthesizer.synthesize(from: prompt) {
                    resolvedTitle = synthesized
                    isCustom = false
                } else {
                    resolvedTitle = nil
                    isCustom = false
                }

                guard let finalTitle = resolvedTitle else { continue }

                let date = entry.updated_at.flatMap { isoFormatter.date(from: $0) }
                let resolvedCwd = entry.cwd.map { URL(fileURLWithPath: $0) } ?? cwdByID[entry.id] ?? sessionsByID[entry.id]?.workingDirectory

                sessionsByID[entry.id] = DiscoveredAgentSession(
                    id: entry.id,
                    title: finalTitle,
                    workingDirectory: resolvedCwd,
                    lastActiveAt: date ?? sessionsByID[entry.id]?.lastActiveAt,
                    agent: .codexCLI,
                    isCustomTitle: isCustom
                )
            }
        }

        return Array(sessionsByID.values)
            .sorted { ($0.lastActiveAt ?? .distantPast) > ($1.lastActiveAt ?? .distantPast) }
    }

    public func fetchLatestSession(for workingDirectory: URL, since: Date?) async throws -> DiscoveredAgentSession? {
        let sessions = try await fetchSessions()
        let target = workingDirectory.standardizedFileURL.path

        return sessions.first { session in
            guard let dir = session.workingDirectory?.standardizedFileURL.path else { return false }
            let matchesPath = (dir == target || target.hasPrefix(dir) || dir.hasPrefix(target))
            guard matchesPath else { return false }

            if let since {
                return (session.lastActiveAt ?? .distantPast) >= since
            }
            return true
        }
    }

    private func fetchSessionsFromDatabase() -> [(id: String, session: DiscoveredAgentSession?, cwd: URL?)] {
        var db: OpaquePointer?
        guard sqlite3_open_v2(databaseURL.path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK, let db else {
            return []
        }
        defer { sqlite3_close(db) }

        let query = "SELECT id, name, title, cwd, updated_at FROM threads ORDER BY updated_at DESC;"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, query, -1, &stmt, nil) == SQLITE_OK, let stmt else {
            return []
        }
        defer { sqlite3_finalize(stmt) }

        var results: [(id: String, session: DiscoveredAgentSession?, cwd: URL?)] = []

        while sqlite3_step(stmt) == SQLITE_ROW {
            guard let idCStr = sqlite3_column_text(stmt, 0) else { continue }
            let id = String(cString: idCStr)

            let cwd: URL? = sqlite3_column_text(stmt, 3).map { URL(fileURLWithPath: String(cString: $0)) }
            let updatedSeconds = sqlite3_column_int64(stmt, 4)
            let date: Date? = updatedSeconds > 0 ? Date(timeIntervalSince1970: Double(updatedSeconds)) : nil

            let nameCStr = sqlite3_column_text(stmt, 1)
            let rawName = nameCStr != nil ? String(cString: nameCStr!).trimmingCharacters(in: .whitespacesAndNewlines) : ""

            let titleCStr = sqlite3_column_text(stmt, 2)
            let rawTitle = titleCStr != nil ? String(cString: titleCStr!).trimmingCharacters(in: .whitespacesAndNewlines) : ""

            let resolvedTitle: String?
            let isCustom: Bool
            if !rawName.isEmpty && !rawName.contains("\n") && rawName.count <= 100 {
                resolvedTitle = rawName
                isCustom = true
            } else if !rawTitle.isEmpty, let synthesized = TitleSynthesizer.synthesize(from: rawTitle) {
                resolvedTitle = synthesized
                isCustom = false
            } else {
                resolvedTitle = nil
                isCustom = false
            }

            if let resolvedTitle {
                let session = DiscoveredAgentSession(
                    id: id,
                    title: resolvedTitle,
                    workingDirectory: cwd,
                    lastActiveAt: date,
                    agent: .codexCLI,
                    isCustomTitle: isCustom
                )
                results.append((id: id, session: session, cwd: cwd))
            } else {
                results.append((id: id, session: nil, cwd: cwd))
            }
        }

        return results
    }
}

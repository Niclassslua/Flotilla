import Foundation
import SessionKit
import SQLite3

/// Discovers sessions managed by OpenCode via its local REST server (`:4096`)
/// with a resilient fallback to the local SQLite database at `~/.local/share/opencode/opencode.db`.
public struct OpenCodeSessionProvider: AgentSessionProviding {
    public let agent: AgentKind = .openCode
    public let serverURL: URL
    public let databaseURL: URL

    public init(
        serverURL: URL = URL(string: "http://127.0.0.1:4096")!,
        databaseURL: URL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".local/share/opencode/opencode.db")
    ) {
        self.serverURL = serverURL
        self.databaseURL = databaseURL
    }

    private struct OpenCodeSessionDTO: Decodable {
        let id: String
        let title: String?
        let directory: String?
        let time_updated: Double?
        let updatedAt: Date?
    }

    public func fetchSessions() async throws -> [DiscoveredAgentSession] {
        // 1. Try local HTTP server first
        if let httpSessions = await fetchSessionsViaHTTP() {
            return httpSessions
        }

        // 2. Fall back to local SQLite database if server isn't running
        return fetchSessionsViaDatabase()
    }

    public func fetchLatestSession(for workingDirectory: URL, since: Date? = nil) async throws -> DiscoveredAgentSession? {
        let all = try await fetchSessions()
        let targetPath = workingDirectory.standardizedFileURL.path

        return all
            .filter { session in
                guard let dir = session.workingDirectory?.standardizedFileURL.path else { return false }
                let matchesPath = (dir == targetPath || targetPath.hasPrefix(dir) || dir.hasPrefix(targetPath))
                guard matchesPath else { return false }

                if let since {
                    return (session.lastActiveAt ?? .distantPast) >= since
                }
                return true
            }
            .sorted { ($0.lastActiveAt ?? .distantPast) > ($1.lastActiveAt ?? .distantPast) }
            .first
    }

    private func fetchSessionsViaHTTP() async -> [DiscoveredAgentSession]? {
        let endpoint = serverURL.appendingPathComponent("session")
        var request = URLRequest(url: endpoint)
        request.timeoutInterval = 1.0

        guard let (data, response) = try? await URLSession.shared.data(for: request),
              let httpResponse = response as? HTTPURLResponse,
              httpResponse.statusCode == 200 else {
            return nil
        }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let dtos = try? decoder.decode([OpenCodeSessionDTO].self, from: data) else {
            return nil
        }

        return dtos.compactMap { dto in
            let rawTitle = dto.title?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let cleanTitle: String
            let isCustom: Bool
            if !rawTitle.isEmpty && !rawTitle.hasPrefix("New session - ") && !rawTitle.contains("\n") && rawTitle.count <= 120 {
                cleanTitle = rawTitle
                isCustom = true
            } else if let synthesized = TitleSynthesizer.synthesize(from: rawTitle) {
                cleanTitle = synthesized
                isCustom = false
            } else {
                return nil
            }

            let date: Date?
            if let timeUpdated = dto.time_updated {
                date = Date(timeIntervalSince1970: timeUpdated > 1_000_000_000_000 ? timeUpdated / 1000 : timeUpdated)
            } else {
                date = dto.updatedAt
            }

            return DiscoveredAgentSession(
                id: dto.id,
                title: cleanTitle,
                workingDirectory: dto.directory.map { URL(fileURLWithPath: $0) },
                lastActiveAt: date,
                agent: .openCode,
                isCustomTitle: isCustom
            )
        }
    }

    public func fetchSessionsViaDatabase() -> [DiscoveredAgentSession] {
        guard FileManager.default.fileExists(atPath: databaseURL.path) else { return [] }

        var db: OpaquePointer?
        guard sqlite3_open_v2(databaseURL.path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK, let db else {
            return []
        }
        defer { sqlite3_close(db) }

        // Query session table along with the first user prompt from the part table
        let query = """
        SELECT s.id, s.title, s.directory, s.time_updated,
               (SELECT p.data FROM part p WHERE p.session_id = s.id AND p.data LIKE '%"type":"text"%' ORDER BY p.time_created ASC LIMIT 1)
        FROM session s ORDER BY s.time_updated DESC;
        """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, query, -1, &stmt, nil) == SQLITE_OK, let stmt else {
            return []
        }
        defer { sqlite3_finalize(stmt) }

        var results: [DiscoveredAgentSession] = []

        while sqlite3_step(stmt) == SQLITE_ROW {
            guard let idCStr = sqlite3_column_text(stmt, 0) else { continue }
            let id = String(cString: idCStr)

            let titleCStr = sqlite3_column_text(stmt, 1)
            let rawTitle = titleCStr != nil ? String(cString: titleCStr!).trimmingCharacters(in: .whitespacesAndNewlines) : ""

            let partCStr = sqlite3_column_text(stmt, 4)
            let partJSON = partCStr != nil ? String(cString: partCStr!) : nil

            let resolvedTitle: String?
            let isCustom: Bool
            if !rawTitle.isEmpty && !rawTitle.hasPrefix("New session - ") && !rawTitle.contains("\n") && rawTitle.count <= 120 {
                resolvedTitle = rawTitle
                isCustom = true
            } else if let partJSON, let rawText = extractRawTextFromPart(partJSON), let synthesized = TitleSynthesizer.synthesize(from: rawText) {
                resolvedTitle = synthesized
                isCustom = false
            } else if !rawTitle.isEmpty && !rawTitle.hasPrefix("New session - ") {
                resolvedTitle = TitleSynthesizer.synthesize(from: rawTitle)
                isCustom = false
            } else {
                resolvedTitle = nil
                isCustom = false
            }

            guard let finalTitle = resolvedTitle else { continue }

            let directory: String?
            if let dirCStr = sqlite3_column_text(stmt, 2) {
                directory = String(cString: dirCStr)
            } else {
                directory = nil
            }

            let timeUpdated = sqlite3_column_int64(stmt, 3)
            let date: Date? = timeUpdated > 0
                ? Date(timeIntervalSince1970: timeUpdated > 1_000_000_000_000 ? Double(timeUpdated) / 1000.0 : Double(timeUpdated))
                : nil

            results.append(DiscoveredAgentSession(
                id: id,
                title: finalTitle,
                workingDirectory: directory.map { URL(fileURLWithPath: $0) },
                lastActiveAt: date,
                agent: .openCode,
                isCustomTitle: isCustom
            ))
        }

        return results
    }

    private func extractRawTextFromPart(_ jsonString: String) -> String? {
        guard let data = jsonString.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let text = json["text"] as? String else { return nil }
        return text
    }
}

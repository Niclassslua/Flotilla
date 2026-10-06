import Foundation
import SessionKit
import SQLite3
import ProcessKit

/// Discovers sessions managed by OpenCode through its own
/// `opencode session list --format json` (verified 1.18.34), falling back to
/// reading `~/.local/share/opencode/opencode.db` when the CLI isn't on `PATH`
/// or fails.
///
/// The session a Flotilla launch started is normally already known: the
/// plugin's `session.created` event pins it (`HookEventReceiver`). This
/// provider supplies titles, and the id for sessions started before that
/// event existed.
public struct OpenCodeSessionProvider: AgentSessionProviding {
    public let agent: AgentKind = .openCode
    public let databaseURL: URL
    private let locator: ExecutableLocating
    private let runner: CommandRunning

    public init(
        databaseURL: URL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".local/share/opencode/opencode.db"),
        locator: ExecutableLocating = PATHExecutableLocator(),
        runner: CommandRunning = ProcessCommandRunner()
    ) {
        self.databaseURL = databaseURL
        self.locator = locator
        self.runner = runner
    }

    /// One row of `opencode session list --format json`.
    private struct ListedSession: Decodable {
        let id: String
        let title: String?
        let directory: String?
        let created: Double?
        let updated: Double?
    }

    public func fetchSessions() async throws -> [DiscoveredAgentSession] {
        if let listed = await fetchSessionsViaCLI() {
            // OpenCode's CLI can still list its default "New session - …"
            // title. Keep the CLI as the discovery source, but use the local
            // read-only catalog for those rows so Flotilla can synthesize a
            // useful title from the first user text part.
            let unresolved = Set(listed.unresolvedTitleIDs)
            guard !unresolved.isEmpty else { return listed.sessions }
            let recovered = fetchSessionsViaDatabase().filter { unresolved.contains($0.id) }
            let recoveredIDs = Set(recovered.map(\.id))
            return listed.sessions + recovered
                + listed.unresolvedTitleIDs.filter { !recoveredIDs.contains($0) }.map { id in
                    DiscoveredAgentSession(
                        id: id,
                        title: "OpenCode session",
                        workingDirectory: nil,
                        agent: .openCode,
                        isCustomTitle: false
                    )
                }
        }
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

    private func fetchSessionsViaCLI() async -> (sessions: [DiscoveredAgentSession], unresolvedTitleIDs: [String])? {
        guard let executable = locator.locate("opencode"),
              let result = try? await runner.run(
                  ["session", "list", "--format", "json"],
                  executable: executable,
                  workingDirectory: FileManager.default.temporaryDirectory
              ),
              result.exitCode == 0,
              let start = result.stdout.firstIndex(where: { $0 == "[" }),
              let listed = try? JSONDecoder().decode([ListedSession].self, from: Data(result.stdout[start...].utf8))
        else { return nil }
        return (Self.sessions(from: listed), listed.compactMap { row in
            let title = row.title?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return title.isEmpty || title.hasPrefix("New session - ") ? row.id : nil
        })
    }

    private static func sessions(from listed: [ListedSession]) -> [DiscoveredAgentSession] {
        listed.compactMap { row in
            let rawTitle = row.title?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            // "New session - <ISO date>" is OpenCode's placeholder until it
            // titles the conversation.
            guard !rawTitle.isEmpty, !rawTitle.hasPrefix("New session - "),
                  !rawTitle.contains("\n"), rawTitle.count <= 120 else { return nil }
            return DiscoveredAgentSession(
                id: row.id,
                title: rawTitle,
                workingDirectory: row.directory.map { URL(fileURLWithPath: $0) },
                createdAt: row.created.map(Self.date(fromTimestamp:)),
                lastActiveAt: (row.updated ?? row.created).map(Self.date(fromTimestamp:)),
                agent: .openCode,
                isCustomTitle: true
            )
        }
    }

    private static func date(fromTimestamp value: Double) -> Date {
        Date(timeIntervalSince1970: value > 1_000_000_000_000 ? value / 1000 : value)
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

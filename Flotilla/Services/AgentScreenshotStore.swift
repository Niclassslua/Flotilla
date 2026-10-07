import Foundation

/// Keeps a copy of every screenshot an agent sent, per session, so the panel
/// still has it after a relaunch. The transcript can't be relied on for that:
/// Claude's `SendUserFile` records only a path, and the scratchpad or worktree
/// it points into is usually gone by the time the session is reopened.
actor AgentScreenshotStore {
    struct Record: Codable, Sendable {
        let id: String
        let line: Int
        let entry: Int
        let filename: String?
        let timestamp: Date
        /// The image file's name inside the session's directory.
        let file: String
    }

    /// A screenshot as stored: its record plus the image bytes.
    struct Stored: Sendable {
        let record: Record
        let data: Data
    }

    private let supportDirectory: URL

    init(supportDirectory: URL = TmuxSessionWrapping.defaultSupportDirectory()) {
        self.supportDirectory = supportDirectory
    }

    /// Where a session's screenshots live; removed with the session.
    static func directory(for sessionID: UUID, supportDirectory: URL) -> URL {
        supportDirectory
            .appendingPathComponent("Screenshots", isDirectory: true)
            .appendingPathComponent(sessionID.uuidString, isDirectory: true)
    }

    /// Every stored screenshot whose image is still readable, oldest first.
    func load(_ sessionID: UUID) -> [Stored] {
        let directory = Self.directory(for: sessionID, supportDirectory: supportDirectory)
        return records(in: directory).compactMap { record in
            guard let data = try? Data(contentsOf: directory.appendingPathComponent(record.file)) else { return nil }
            return Stored(record: record, data: data)
        }
    }

    /// Adds `screenshots` that aren't stored yet. Images are written before
    /// the index, so an interrupted save never indexes a missing file.
    func save(_ screenshots: [Stored], for sessionID: UUID) {
        let directory = Self.directory(for: sessionID, supportDirectory: supportDirectory)
        var records = records(in: directory)
        let known = Set(records.map(\.id))
        let added = screenshots.filter { !known.contains($0.record.id) }
        guard !added.isEmpty else { return }
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            for screenshot in added {
                try screenshot.data.write(to: directory.appendingPathComponent(screenshot.record.file), options: .atomic)
                records.append(screenshot.record)
            }
            try JSONEncoder().encode(records).write(to: indexURL(in: directory), options: .atomic)
        } catch {
            // A screenshot that couldn't be stored is still shown this launch.
        }
    }

    /// The image file name for a transcript event id such as `"412:1"`.
    static func fileName(for id: String) -> String {
        id.map { $0.isLetter || $0.isNumber ? String($0) : "_" }.joined() + ".img"
    }

    private func records(in directory: URL) -> [Record] {
        guard let data = try? Data(contentsOf: indexURL(in: directory)) else { return [] }
        return (try? JSONDecoder().decode([Record].self, from: data)) ?? []
    }

    private func indexURL(in directory: URL) -> URL {
        directory.appendingPathComponent("index.json")
    }
}

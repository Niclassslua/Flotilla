import Foundation
import SessionKit

/// Discovers sessions managed by Claude Code under `~/.claude/projects/`.
public struct ClaudeSessionProvider: AgentSessionProviding {
    public let agent: AgentKind = .claudeCode
    public let claudeBaseURL: URL

    public init(claudeBaseURL: URL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude")) {
        self.claudeBaseURL = claudeBaseURL
    }

    public func fetchSessions() async throws -> [DiscoveredAgentSession] {
        let projectsURL = claudeBaseURL.appendingPathComponent("projects")
        guard FileManager.default.fileExists(atPath: projectsURL.path) else { return [] }

        let projectFolders = (try? FileManager.default.contentsOfDirectory(
            at: projectsURL,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )) ?? []

        var allSessions: [DiscoveredAgentSession] = []

        for folder in projectFolders {
            let files = (try? FileManager.default.contentsOfDirectory(
                at: folder,
                includingPropertiesForKeys: [.contentModificationDateKey],
                options: [.skipsHiddenFiles]
            )) ?? []

            for file in files where file.pathExtension == "jsonl" {
                if let session = try? parseClaudeSessionFile(file) {
                    allSessions.append(session)
                }
            }
        }

        return allSessions.sorted { ($0.lastActiveAt ?? .distantPast) > ($1.lastActiveAt ?? .distantPast) }
    }

    public func fetchLatestSession(for workingDirectory: URL, since: Date? = nil) async throws -> DiscoveredAgentSession? {
        let projectsURL = claudeBaseURL.appendingPathComponent("projects")
        guard FileManager.default.fileExists(atPath: projectsURL.path) else { return nil }

        let targetStandardized = workingDirectory.standardizedFileURL.path
        let candidateFolderNames = slugVariants(for: targetStandardized)

        let projectFolders = (try? FileManager.default.contentsOfDirectory(
            at: projectsURL,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )) ?? []

        // Find folder that matches any slug variant or folder basename
        let matchingFolders = projectFolders.filter { folder in
            let name = folder.lastPathComponent
            return candidateFolderNames.contains(name)
                || candidateFolderNames.contains { name.hasPrefix($0 + "-") && $0.utf16.count == 200 }
                || name.hasSuffix(workingDirectory.lastPathComponent)
                || name.contains(workingDirectory.lastPathComponent)
        }

        var candidateFiles: [URL] = []
        for folder in matchingFolders {
            let files = (try? FileManager.default.contentsOfDirectory(
                at: folder,
                includingPropertiesForKeys: [.contentModificationDateKey],
                options: [.skipsHiddenFiles]
            )) ?? []
            candidateFiles.append(contentsOf: files.filter { $0.pathExtension == "jsonl" })
        }

        let sortedFiles = candidateFiles.sorted { fileA, fileB in
            let dateA = (try? fileA.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            let dateB = (try? fileB.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            return dateA > dateB
        }

        for file in sortedFiles {
            if let session = try? parseClaudeSessionFile(file, overrideWorkingDirectory: workingDirectory) {
                if let since {
                    if (session.lastActiveAt ?? .distantPast) >= since {
                        return session
                    }
                } else {
                    return session
                }
            }
        }

        return nil
    }

    private func slugVariants(for path: String) -> [String] {
        let slug1 = path.replacingOccurrences(of: "/", with: "-")
        let slug2 = slug1.replacingOccurrences(of: ".", with: "-")
        let slug3 = slug1.replacingOccurrences(of: "-.", with: "--")
        let slug4 = path.replacingOccurrences(of: "/.", with: "--").replacingOccurrences(of: "/", with: "-")
        // Current Claude (2.1.291): every non-alphanumeric UTF-16 unit is a
        // dash; past 200 units the name is cut there and a hash appended,
        // which the prefix match above accepts.
        let sanitized = String(decoding: path.utf16.map { unit -> UInt16 in
            switch unit {
            case 0x30...0x39, 0x41...0x5A, 0x61...0x7A: unit
            default: 0x2D
            }
        }, as: UTF16.self)
        let slug5 = String(decoding: sanitized.utf16.prefix(200), as: UTF16.self)
        return [slug1, slug2, slug3, slug4, slug5]
    }

    public func parseClaudeSessionFile(_ fileURL: URL, overrideWorkingDirectory: URL? = nil) throws -> DiscoveredAgentSession? {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return nil }
        guard let handle = try? FileHandle(forReadingFrom: fileURL) else { return nil }
        defer { try? handle.close() }

        let modificationDate = try? fileURL.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
        let sessionID = fileURL.deletingPathExtension().lastPathComponent

        // Read up to 256 KB (where initial events, prompt, and ai-title reside)
        let headData = handle.readData(ofLength: 256 * 1024)
        guard let headContent = String(data: headData, encoding: .utf8) else { return nil }

        var aiTitle: String?
        var customTitle: String?
        var promptTitle: String?
        var cwd: String?

        for line in headContent.split(separator: "\n") {
            guard line.contains("title") || line.contains("cwd") || line.contains("\"user\"") else { continue }
            guard let lineData = line.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any] else { continue }

            if let type = json["type"] as? String {
                if type == "custom-title", let title = json["customTitle"] as? String, !title.isEmpty {
                    customTitle = title
                } else if type == "ai-title", let title = json["aiTitle"] as? String, !title.isEmpty {
                    aiTitle = title
                } else if promptTitle == nil, type == "user",
                          let message = json["message"] as? [String: Any],
                          let content = message["content"] as? String {
                    let firstLine = content.components(separatedBy: .newlines).first ?? content
                    let clean = firstLine.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !clean.isEmpty {
                        promptTitle = String(clean.prefix(60))
                    }
                }
            }
            if let dir = json["cwd"] as? String {
                cwd = dir
            }
        }

        // Also check last 32 KB for any late custom-title / rename event
        let fileSize = (try? fileURL.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        if fileSize > 256 * 1024 {
            let tailOffset = max(0, UInt64(fileSize) - 32 * 1024)
            try? handle.seek(toOffset: tailOffset)
            let tailData = handle.readDataToEndOfFile()
            if let tailContent = String(data: tailData, encoding: .utf8) {
                for line in tailContent.split(separator: "\n") {
                    guard line.contains("custom-title") else { continue }
                    guard let lineData = line.data(using: .utf8),
                          let json = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any],
                          let type = json["type"] as? String, type == "custom-title",
                          let title = json["customTitle"] as? String, !title.isEmpty else { continue }
                    customTitle = title
                }
            }
        }

        guard let resolvedTitle = customTitle ?? aiTitle ?? promptTitle else { return nil }
        let cleanTitle = resolvedTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanTitle.isEmpty, !cleanTitle.contains("\n"), cleanTitle.count <= 120 else { return nil }

        let resolvedCwd: URL?
        if let overrideWorkingDirectory {
            resolvedCwd = overrideWorkingDirectory
        } else if let cwd {
            resolvedCwd = URL(fileURLWithPath: dirUnslug(cwd))
        } else {
            resolvedCwd = nil
        }

        return DiscoveredAgentSession(
            id: sessionID,
            title: cleanTitle,
            workingDirectory: resolvedCwd,
            lastActiveAt: modificationDate,
            agent: .claudeCode,
            isCustomTitle: customTitle != nil
        )
    }

    private func dirUnslug(_ slug: String) -> String {
        if slug.hasPrefix("-") {
            return slug.replacingOccurrences(of: "-", with: "/")
        }
        return slug
    }
}

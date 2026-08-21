import Foundation
import Observation
import os
import SessionKit

/// Traces every filesystem scan Flotilla performs, so a "why did macOS just
/// ask for my X folder" report can be root-caused from a Console.app filter
/// on subsystem `com.niclassslua.flotilla` / category `FileScan`, instead of
/// guessed at from source.
let fileScanLog = Logger(subsystem: "com.niclassslua.flotilla", category: "FileScan")

struct FileNode: Identifiable, Hashable, Sendable {
    let url: URL
    let isDirectory: Bool
    var children: [FileNode]?

    var id: URL { url }
    var name: String { url.lastPathComponent }
}

struct RuleFileEntry: Identifiable, Hashable, Sendable {
    let url: URL
    let relativePath: String
    let scope: RuleScope

    var id: URL { url }
    var name: String { relativePath }
}

enum RuleScope: String, Sendable, Hashable {
    case global
    case project
}

public enum SkillScope: String, Sendable, Hashable, Codable {
    case global
    case project
}

public enum SkillFramework: String, Sendable, Hashable, Codable, CaseIterable {
    case claude
    case agents
    case codex
    case cursor
    case gemini
    case custom

    public var displayName: String {
        switch self {
        case .claude: return "Claude"
        case .agents: return "Agents"
        case .codex: return "Codex"
        case .cursor: return "Cursor"
        case .gemini: return "Gemini"
        case .custom: return "Custom"
        }
    }

    public var agentKind: AgentKind? {
        switch self {
        case .claude: return .claudeCode
        case .codex: return .codexCLI
        case .gemini: return .antigravity
        case .agents, .cursor, .custom: return nil
        }
    }

    public var logoAssetName: String? {
        switch self {
        case .claude: return "ProviderLogoClaude"
        case .codex: return "ProviderLogoCodex"
        case .cursor: return "ProviderLogoCursor"
        case .gemini: return "ProviderLogoAntigravity"
        case .agents, .custom: return nil
        }
    }

    public var iconSystemName: String {
        switch self {
        case .claude: return "sparkles"
        case .agents: return "person.2.badge.gearshape"
        case .codex: return "chevron.left.forwardslash.chevron.right"
        case .cursor: return "cursorarrow.rays"
        case .gemini: return "wand.and.stars"
        case .custom: return "puzzlepiece.extension.fill"
        }
    }
}

public struct SkillBundleStats: Sendable, Hashable, Codable {
    public var scriptsCount: Int
    public var referencesCount: Int
    public var dataCount: Int
    public var totalFilesCount: Int
    public var lineCount: Int
    public var wordCount: Int
    public var estimatedReadMinutes: Int
    public var lastModified: Date?

    public init(
        scriptsCount: Int = 0,
        referencesCount: Int = 0,
        dataCount: Int = 0,
        totalFilesCount: Int = 0,
        lineCount: Int = 0,
        wordCount: Int = 0,
        estimatedReadMinutes: Int = 1,
        lastModified: Date? = nil
    ) {
        self.scriptsCount = scriptsCount
        self.referencesCount = referencesCount
        self.dataCount = dataCount
        self.totalFilesCount = totalFilesCount
        self.lineCount = lineCount
        self.wordCount = wordCount
        self.estimatedReadMinutes = estimatedReadMinutes
        self.lastModified = lastModified
    }
}

public struct SkillEntry: Identifiable, Hashable, Sendable {
    public let url: URL              // the SKILL.md
    public let name: String          // frontmatter `name`, else directory name
    public let description: String   // frontmatter `description`
    public let scope: SkillScope     // .global | .project
    public let framework: SkillFramework
    public let source: String?       // plugin name when under ~/.claude/plugins
    public let version: String?
    public let argumentHint: String?
    public let userInvocable: Bool?
    public let author: String?
    public let license: String?
    public let tags: [String]
    public let bundleStats: SkillBundleStats
    public var id: URL { url }

    public init(
        url: URL,
        name: String,
        description: String,
        scope: SkillScope,
        framework: SkillFramework = .custom,
        source: String? = nil,
        version: String? = nil,
        argumentHint: String? = nil,
        userInvocable: Bool? = nil,
        author: String? = nil,
        license: String? = nil,
        tags: [String] = [],
        bundleStats: SkillBundleStats = SkillBundleStats()
    ) {
        self.url = url
        self.name = name
        self.description = description
        self.scope = scope
        self.framework = framework
        self.source = source
        self.version = version
        self.argumentHint = argumentHint
        self.userInvocable = userInvocable
        self.author = author
        self.license = license
        self.tags = tags
        self.bundleStats = bundleStats
    }
}

public struct ParsedSkillFrontmatter: Sendable, Hashable {
    public var name: String?
    public var description: String?
    public var version: String?
    public var argumentHint: String?
    public var userInvocable: Bool?
    public var author: String?
    public var license: String?
    public var tags: [String]

    public init(
        name: String? = nil,
        description: String? = nil,
        version: String? = nil,
        argumentHint: String? = nil,
        userInvocable: Bool? = nil,
        author: String? = nil,
        license: String? = nil,
        tags: [String] = []
    ) {
        self.name = name
        self.description = description
        self.version = version
        self.argumentHint = argumentHint
        self.userInvocable = userInvocable
        self.author = author
        self.license = license
        self.tags = tags
    }
}

public enum SkillFrontmatter {
    public static func parse(_ text: String) -> ParsedSkillFrontmatter {
        let normalized = text
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        let lines = normalized.components(separatedBy: "\n")

        guard let first = lines.first, first.trimmingCharacters(in: .whitespaces) == "---" else {
            return ParsedSkillFrontmatter()
        }

        var name: String?
        var description: String?
        var version: String?
        var argumentHint: String?
        var userInvocable: Bool?
        var author: String?
        var license: String?
        var tags: [String] = []

        var i = 1
        var currentKey: String?
        var currentValue: [String] = []

        func flushCurrent() {
            guard let key = currentKey?.lowercased() else { return }
            let combined = currentValue.joined(separator: " ").trimmingCharacters(in: .whitespaces)
            let unquoted = stripQuotes(combined)

            switch key {
            case "name":
                name = unquoted
            case "description":
                description = unquoted
            case "version":
                version = unquoted
            case "argument-hint", "argument_hint", "arguments":
                argumentHint = unquoted
            case "user-invocable", "user_invocable":
                if unquoted.lowercased() == "true" {
                    userInvocable = true
                } else if unquoted.lowercased() == "false" {
                    userInvocable = false
                }
            case "author":
                author = unquoted
            case "license":
                license = unquoted
            case "tags", "keywords", "categories":
                if unquoted.hasPrefix("[") && unquoted.hasSuffix("]") {
                    let inner = unquoted.dropFirst().dropLast()
                    tags = inner.components(separatedBy: ",")
                        .map { stripQuotes($0.trimmingCharacters(in: .whitespaces)) }
                        .filter { !$0.isEmpty }
                } else if !unquoted.isEmpty {
                    tags = currentValue
                        .map { line in
                            var t = line.trimmingCharacters(in: .whitespaces)
                            if t.hasPrefix("-") { t = String(t.dropFirst()).trimmingCharacters(in: .whitespaces) }
                            return stripQuotes(t)
                        }
                        .filter { !$0.isEmpty }
                }
            default:
                break
            }
            currentKey = nil
            currentValue = []
        }

        var hasClosed = false

        while i < lines.count {
            let line = lines[i]
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed == "---" {
                hasClosed = true
                flushCurrent()
                break
            }

            if line.hasPrefix(" ") || line.hasPrefix("\t") || trimmed.hasPrefix("-") {
                if currentKey != nil {
                    currentValue.append(trimmed)
                }
            } else if let colonIdx = line.firstIndex(of: ":") {
                flushCurrent()
                let key = String(line[..<colonIdx]).trimmingCharacters(in: .whitespaces)
                let val = String(line[line.index(after: colonIdx)...]).trimmingCharacters(in: .whitespaces)
                currentKey = key
                if !val.isEmpty && val != ">" && val != ">-" && val != "|" {
                    currentValue.append(val)
                }
            }
            i += 1
        }

        guard hasClosed else { return ParsedSkillFrontmatter() }
        return ParsedSkillFrontmatter(
            name: name,
            description: description,
            version: version,
            argumentHint: argumentHint,
            userInvocable: userInvocable,
            author: author,
            license: license,
            tags: tags
        )
    }

    public static func parseWithFallback(_ text: String, fallbackDirName: String) -> ParsedSkillFrontmatter {
        var parsed = parse(text)
        if parsed.name != nil && parsed.description != nil {
            return parsed
        }

        let normalized = text
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        let lines = normalized.components(separatedBy: "\n")

        var extractedTitle: String?
        var extractedDesc: String?

        var readingParagraph = false
        var paragraphLines: [String] = []

        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty || trimmed == "---" {
                if readingParagraph && !paragraphLines.isEmpty {
                    break
                }
                continue
            }

            if extractedTitle == nil && trimmed.hasPrefix("#") {
                var headerText = trimmed.drop(while: { $0 == "#" }).trimmingCharacters(in: .whitespaces)
                if headerText.hasPrefix("`") && headerText.hasSuffix("`") {
                    headerText = String(headerText.dropFirst().dropLast())
                }
                if !headerText.isEmpty {
                    extractedTitle = headerText
                }
                continue
            }

            if !trimmed.hasPrefix("#") && !trimmed.hasPrefix("```") && !trimmed.hasPrefix("!") {
                readingParagraph = true
                paragraphLines.append(trimmed)
            }
        }

        if !paragraphLines.isEmpty {
            extractedDesc = paragraphLines.joined(separator: " ")
        }

        if parsed.name == nil {
            parsed.name = extractedTitle ?? fallbackDirName
        }
        if parsed.description == nil {
            parsed.description = extractedDesc ?? ""
        }
        return parsed
    }

    private static func stripQuotes(_ s: String) -> String {
        var str = s.trimmingCharacters(in: .whitespaces)
        if (str.hasPrefix("\"") && str.hasSuffix("\"")) || (str.hasPrefix("'") && str.hasSuffix("'")) {
            str = String(str.dropFirst().dropLast())
        }
        return str.trimmingCharacters(in: .whitespaces)
    }
}

protocol WorkspaceFileServicing: Sendable {
    func fileTree(at root: URL) async throws -> [FileNode]
    func instructionFiles(in root: URL) async throws -> [RuleFileEntry]
    func globalInstructionFiles() async throws -> [RuleFileEntry]
    func skills(projectRoot: URL) async throws -> [SkillEntry]
    func readText(at url: URL) async throws -> String
    func writeText(_ text: String, to url: URL) async throws
}

struct WorkspaceFileService: WorkspaceFileServicing {
    let homeDirectoryProvider: @Sendable () -> URL

    init(homeDirectoryProvider: @escaping @Sendable () -> URL = { FileManager.default.homeDirectoryForCurrentUser }) {
        self.homeDirectoryProvider = homeDirectoryProvider
    }

    func fileTree(at root: URL) async throws -> [FileNode] {
        return try await Task.detached {
            try Self.loadChildren(of: root, depth: 0, fileManager: .default)
        }.value
    }

    func instructionFiles(in root: URL) async throws -> [RuleFileEntry] {
        return try await Task.detached {
            try Self.discoverInstructionFiles(in: root, fileManager: .default)
        }.value
    }

    func readText(at url: URL) async throws -> String {
        try await Task.detached {
            try String(contentsOf: url, encoding: .utf8)
        }.value
    }

    func writeText(_ text: String, to url: URL) async throws {
        try await Task.detached {
            try text.write(to: url, atomically: true, encoding: .utf8)
        }.value
    }

    func globalInstructionFiles() async throws -> [RuleFileEntry] {
        let home = homeDirectoryProvider()
        return try await Task.detached {
            Self.discoverGlobalInstructionFiles(home: home, fileManager: .default)
        }.value
    }

    func skills(projectRoot: URL) async throws -> [SkillEntry] {
        let home = homeDirectoryProvider()
        return try await Task.detached {
            Self.discoverSkills(projectRoot: projectRoot, home: home, fileManager: .default)
        }.value
    }

    private static let excludedDirectories = Set([
        ".git", ".build", "DerivedData", "node_modules", "Pods", ".swiftpm"
    ])

    /// The real, resolved paths of macOS's TCC-protected user folders
    /// (Desktop, Documents, Downloads, Music, Pictures, Movies). Reading the
    /// *contents* of one of these triggers a system "Allow access" prompt.
    /// Matched by actual path rather than by name, so a project's own
    /// subfolder that happens to be called e.g. "Downloads" or "Library"
    /// isn't skipped — only the genuine system folders are, which only show
    /// up as scan targets at all when a project root was chosen broadly
    /// enough (e.g. the home directory) to contain them as real children.
    private static let tccProtectedPaths: Set<String> = {
        let fm = FileManager.default
        let domains: [FileManager.SearchPathDirectory] = [
            .desktopDirectory, .documentDirectory, .downloadsDirectory,
            .musicDirectory, .picturesDirectory, .moviesDirectory
        ]
        return Set(domains.compactMap {
            fm.urls(for: $0, in: .userDomainMask).first?.resolvingSymlinksInPath().standardizedFileURL.path
        })
    }()

    /// Shared with any other filesystem scanner in the app (e.g. the Import
    /// Workspace path resolver) that needs to avoid touching these folders.
    static func isTCCProtected(_ url: URL) -> Bool {
        let protected = tccProtectedPaths.contains(url.resolvingSymlinksInPath().standardizedFileURL.path)
        if protected {
            fileScanLog.notice("skipping TCC-protected folder: \(url.path, privacy: .public)")
        }
        return protected
    }

    private static let ignoredFileNames = Set([
        ".ds_store", "thumbs.db", ".localized"
    ])

    private static func loadChildren(
        of directory: URL,
        depth: Int,
        fileManager: FileManager
    ) throws -> [FileNode] {
        guard depth < 8 else { return [] }
        fileScanLog.notice("loadChildren: listing contents of \(directory.path, privacy: .public) (depth \(depth))")
        let entries = try fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
            options: []
        )
        return try entries
            .filter {
                let name = $0.lastPathComponent.lowercased()
                if ignoredFileNames.contains(name) { return false }
                if excludedDirectories.contains($0.lastPathComponent) { return false }
                if isTCCProtected($0) { return false }
                return true
            }
            .map { url in
                let values = try url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
                let isDirectory = values.isDirectory == true && values.isSymbolicLink != true
                return FileNode(
                    url: url,
                    isDirectory: isDirectory,
                    children: isDirectory ? try loadChildren(of: url, depth: depth + 1, fileManager: fileManager) : nil
                )
            }
            .sorted {
                if $0.isDirectory != $1.isDirectory { return $0.isDirectory }
                return $0.name.localizedStandardCompare($1.name) == .orderedAscending
            }
    }

    private static func discoverInstructionFiles(
        in root: URL,
        fileManager: FileManager
    ) throws -> [RuleFileEntry] {
        let canonicalRoot = root.resolvingSymlinksInPath().standardizedFileURL
        let keys: [URLResourceKey] = [.isRegularFileKey, .isDirectoryKey, .isSymbolicLinkKey]
        fileScanLog.notice("discoverInstructionFiles: recursive scan rooted at \(root.path, privacy: .public)")
        guard let enumerator = fileManager.enumerator(
            at: root,
            includingPropertiesForKeys: keys,
            options: [.skipsPackageDescendants],
            errorHandler: { url, error in
                fileScanLog.error("enumerator error at \(url.path, privacy: .public): \(error.localizedDescription, privacy: .public)")
                return true
            }
        ) else { return [] }

        let instructionNames = Set([
            "CLAUDE.md", "claude.md",
            "AGENTS.md", "agent.md",
            "GEMINI.md", "gemini.md",
            "SKILL.md", "skill.md",
            ".cursorrules", ".cursorignore",
            "copilot-instructions.md",
            ".geminirules", ".geminiignore",
            ".antigravityrules", ".clauderules"
        ])
        var results: [RuleFileEntry] = []
        for case let url as URL in enumerator {
            let values = try url.resourceValues(forKeys: Set(keys))
            if values.isDirectory == true {
                fileScanLog.debug("visiting directory \(url.path, privacy: .public)")
            }
            if values.isSymbolicLink == true {
                if values.isDirectory == true { enumerator.skipDescendants() }
                continue
            }
            if values.isDirectory == true, excludedDirectories.contains(url.lastPathComponent) || isTCCProtected(url) {
                enumerator.skipDescendants()
                continue
            }
            guard values.isRegularFile == true else { continue }

            let filename = url.lastPathComponent
            let ext = url.pathExtension.lowercased()
            let canonicalURL = url.resolvingSymlinksInPath().standardizedFileURL
            let rootPrefix = canonicalRoot.path.hasSuffix("/") ? canonicalRoot.path : canonicalRoot.path + "/"
            guard canonicalURL.path.hasPrefix(rootPrefix) else { continue }
            let relative = String(canonicalURL.path.dropFirst(rootPrefix.count))
            let isKnownInstruction = instructionNames.contains(filename)
            let isAIConfigDir = relative.hasPrefix(".claude/") || relative.hasPrefix(".gemini/") || relative.hasPrefix(".antigravity/") || relative.hasPrefix(".agents/") || relative.hasPrefix(".cursor/") || relative.hasPrefix(".codex/")
            let isInstructionExtension = ext == "md" || ext == "rules" || ext == "prompt"
            let isInsideAIDir = isAIConfigDir && isInstructionExtension
            let isSkill = relative.contains(".claude/skills/")
                || relative.contains(".agents/skills/")
                || relative.contains(".codex/skills/")
                || relative.contains(".gemini/skills/")
                || relative.contains(".antigravity/skills/")

            guard isKnownInstruction || isInsideAIDir || isSkill else { continue }
            results.append(RuleFileEntry(url: url, relativePath: relative, scope: .project))
        }
        return results.sorted { $0.relativePath.localizedStandardCompare($1.relativePath) == .orderedAscending }
    }

    /// Scans well-known global rule file locations. Non-recursive, existence-only
    /// checks — no enumerator, so no TCC surprises.
    private static func discoverGlobalInstructionFiles(
        home: URL,
        fileManager: FileManager
    ) -> [RuleFileEntry] {
        let candidates: [(dir: String, file: String)] = [
            (".claude", "CLAUDE.md"),
            (".claude", "claude.json"),
            (".codex", "AGENTS.md"),
            (".agents", "AGENTS.md"),
            (".gemini", "GEMINI.md"),
            (".gemini", "antigravity.md"),
            (".gemini", "rules.md"),
            (".antigravity", "AGENTS.md"),
            (".antigravity", "GEMINI.md"),
            (".cursor", ".cursorrules"),
        ]
        var results: [RuleFileEntry] = []
        for (dir, file) in candidates {
            let url = home.appendingPathComponent(dir).appendingPathComponent(file)
            fileScanLog.notice("globalInstructionFiles: checking \(url.path, privacy: .public)")
            if fileManager.fileExists(atPath: url.path) {
                let relative = "~/\(dir)/\(file)"
                results.append(RuleFileEntry(url: url, relativePath: relative, scope: .global))
            }
        }
        return results.sorted { $0.relativePath.localizedStandardCompare($1.relativePath) == .orderedAscending }
    }

    private static func inspectSkillBundle(
        skillFile: URL,
        skillText: String,
        fileManager: FileManager
    ) -> SkillBundleStats {
        let folder = skillFile.deletingLastPathComponent()
        var scriptsCount = 0
        var referencesCount = 0
        var dataCount = 0
        var totalFilesCount = 0

        if let enumerator = fileManager.enumerator(
            at: folder,
            includingPropertiesForKeys: [.isRegularFileKey, .isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) {
            for case let fileURL as URL in enumerator {
                guard let values = try? fileURL.resourceValues(forKeys: [.isRegularFileKey, .isDirectoryKey]),
                      values.isRegularFile == true else { continue }

                if fileURL.lastPathComponent.lowercased() == skillFile.lastPathComponent.lowercased() {
                    continue
                }
                totalFilesCount += 1
                let rel = fileURL.path.replacingOccurrences(of: folder.path + "/", with: "")
                let lowerRel = rel.lowercased()
                let ext = fileURL.pathExtension.lowercased()

                if lowerRel.hasPrefix("scripts/") || lowerRel.hasPrefix("bin/") || ext == "py" || ext == "sh" || ext == "bash" || ext == "zsh" {
                    scriptsCount += 1
                } else if lowerRel.hasPrefix("references/") || lowerRel.hasPrefix("docs/") || lowerRel.hasPrefix("reference/") || lowerRel.hasPrefix("guides/") || (ext == "md" && !lowerRel.contains("license") && !lowerRel.contains("notice")) {
                    referencesCount += 1
                } else if lowerRel.hasPrefix("data/") || lowerRel.hasPrefix("resources/") || lowerRel.hasPrefix("assets/") || lowerRel.hasPrefix("templates/") || lowerRel.hasPrefix("examples/") || lowerRel.hasPrefix("tests/") || ext == "csv" || ext == "json" {
                    dataCount += 1
                }
            }
        }

        let lines = skillText.components(separatedBy: "\n")
        let lineCount = lines.count
        let words = skillText.split(whereSeparator: { $0.isWhitespace || $0.isNewline }).count
        let estimatedReadMinutes = max(1, Int(ceil(Double(words) / 180.0)))
        let attributes = try? fileManager.attributesOfItem(atPath: skillFile.path)
        let lastModified = attributes?[.modificationDate] as? Date

        return SkillBundleStats(
            scriptsCount: scriptsCount,
            referencesCount: referencesCount,
            dataCount: dataCount,
            totalFilesCount: totalFilesCount,
            lineCount: lineCount,
            wordCount: words,
            estimatedReadMinutes: estimatedReadMinutes,
            lastModified: lastModified
        )
    }

    /// Discovers skills across global (~/.claude, ~/.agents, ~/.codex, ~/.cursor, ~/.gemini) and project-scoped roots.
    private static func discoverSkills(
        projectRoot: URL,
        home: URL,
        fileManager: FileManager
    ) -> [SkillEntry] {
        var results: [SkillEntry] = []
        var seenPaths = Set<String>()

        func addSkill(skillFile: URL, dirName: String, scope: SkillScope, framework: SkillFramework, source: String?) {
            let canonical = skillFile.resolvingSymlinksInPath().standardizedFileURL.path
            guard !seenPaths.contains(canonical) else { return }
            seenPaths.insert(canonical)

            let text = (try? String(contentsOf: skillFile, encoding: .utf8)) ?? ""
            let parsed = SkillFrontmatter.parseWithFallback(text, fallbackDirName: dirName)
            let stats = inspectSkillBundle(skillFile: skillFile, skillText: text, fileManager: fileManager)

            results.append(SkillEntry(
                url: skillFile,
                name: parsed.name ?? dirName,
                description: parsed.description ?? "",
                scope: scope,
                framework: framework,
                source: source,
                version: parsed.version,
                argumentHint: parsed.argumentHint,
                userInvocable: parsed.userInvocable,
                author: parsed.author,
                license: parsed.license,
                tags: parsed.tags,
                bundleStats: stats
            ))
        }

        func findSkillFile(in directory: URL) -> URL? {
            let candidates = ["SKILL.md", "skill.md", "Skill.md"]
            for name in candidates {
                let candidate = directory.appendingPathComponent(name)
                if fileManager.fileExists(atPath: candidate.path) {
                    return candidate
                }
            }
            return nil
        }

        func scanDirectSkillRoots(baseDir: URL, scope: SkillScope, framework: SkillFramework) {
            guard fileManager.fileExists(atPath: baseDir.path), !isTCCProtected(baseDir) else { return }
            fileScanLog.notice("discoverSkills: scanning direct root \(baseDir.path, privacy: .public)")
            guard let contents = try? fileManager.contentsOfDirectory(at: baseDir, includingPropertiesForKeys: [.isDirectoryKey]) else { return }

            for folder in contents {
                let isDir = (try? folder.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
                guard isDir else { continue }
                if let skillFile = findSkillFile(in: folder) {
                    addSkill(skillFile: skillFile, dirName: folder.lastPathComponent, scope: scope, framework: framework, source: nil)
                } else {
                    // Check 1 level deeper for grouping folders like .system, skills-cursor, builtin, etc.
                    if let nestedDirs = try? fileManager.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.isDirectoryKey]) {
                        for subFolder in nestedDirs {
                            let isSubDir = (try? subFolder.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
                            guard isSubDir else { continue }
                            if let nestedSkillFile = findSkillFile(in: subFolder) {
                                addSkill(skillFile: nestedSkillFile, dirName: subFolder.lastPathComponent, scope: scope, framework: framework, source: nil)
                            }
                        }
                    }
                }
            }
        }

        func scanPluginSkillRoots(pluginsDir: URL, scope: SkillScope, framework: SkillFramework) {
            guard fileManager.fileExists(atPath: pluginsDir.path), !isTCCProtected(pluginsDir) else { return }
            fileScanLog.notice("discoverSkills: scanning plugins root \(pluginsDir.path, privacy: .public)")
            guard let plugins = try? fileManager.contentsOfDirectory(at: pluginsDir, includingPropertiesForKeys: [.isDirectoryKey]) else { return }

            for pluginFolder in plugins {
                let isDir = (try? pluginFolder.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
                guard isDir else { continue }
                let pluginName = pluginFolder.lastPathComponent
                let skillsFolder = pluginFolder.appendingPathComponent("skills")
                guard fileManager.fileExists(atPath: skillsFolder.path) else { continue }

                guard let skillDirs = try? fileManager.contentsOfDirectory(at: skillsFolder, includingPropertiesForKeys: [.isDirectoryKey]) else { continue }
                for folder in skillDirs {
                    let isFolderDir = (try? folder.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
                    guard isFolderDir else { continue }
                    if let skillFile = findSkillFile(in: folder) {
                        addSkill(skillFile: skillFile, dirName: folder.lastPathComponent, scope: scope, framework: framework, source: pluginName)
                    }
                }
            }
        }

        // Global skills
        scanDirectSkillRoots(baseDir: home.appendingPathComponent(".claude/skills"), scope: .global, framework: .claude)
        scanPluginSkillRoots(pluginsDir: home.appendingPathComponent(".claude/plugins"), scope: .global, framework: .claude)
        scanDirectSkillRoots(baseDir: home.appendingPathComponent(".agents/skills"), scope: .global, framework: .agents)
        scanDirectSkillRoots(baseDir: home.appendingPathComponent(".cursor/skills"), scope: .global, framework: .cursor)
        scanDirectSkillRoots(baseDir: home.appendingPathComponent(".cursor/skills-cursor"), scope: .global, framework: .cursor)
        scanDirectSkillRoots(baseDir: home.appendingPathComponent(".codex/skills"), scope: .global, framework: .codex)
        scanDirectSkillRoots(baseDir: home.appendingPathComponent(".gemini/skills"), scope: .global, framework: .gemini)
        scanDirectSkillRoots(baseDir: home.appendingPathComponent(".gemini/antigravity-cli/builtin/skills"), scope: .global, framework: .gemini)
        scanDirectSkillRoots(baseDir: home.appendingPathComponent(".antigravity/skills"), scope: .global, framework: .gemini)

        // Project skills
        scanDirectSkillRoots(baseDir: projectRoot.appendingPathComponent(".claude/skills"), scope: .project, framework: .claude)
        scanPluginSkillRoots(pluginsDir: projectRoot.appendingPathComponent(".claude/plugins"), scope: .project, framework: .claude)
        scanDirectSkillRoots(baseDir: projectRoot.appendingPathComponent(".agents/skills"), scope: .project, framework: .agents)
        scanDirectSkillRoots(baseDir: projectRoot.appendingPathComponent(".agent/skills"), scope: .project, framework: .agents)
        scanDirectSkillRoots(baseDir: projectRoot.appendingPathComponent("_agents/skills"), scope: .project, framework: .agents)
        scanDirectSkillRoots(baseDir: projectRoot.appendingPathComponent(".cursor/skills"), scope: .project, framework: .cursor)
        scanDirectSkillRoots(baseDir: projectRoot.appendingPathComponent(".cursor/skills-cursor"), scope: .project, framework: .cursor)
        scanDirectSkillRoots(baseDir: projectRoot.appendingPathComponent(".codex/skills"), scope: .project, framework: .codex)
        scanDirectSkillRoots(baseDir: projectRoot.appendingPathComponent(".gemini/skills"), scope: .project, framework: .gemini)
        scanDirectSkillRoots(baseDir: projectRoot.appendingPathComponent(".antigravity/skills"), scope: .project, framework: .gemini)

        return results.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }
}

@Observable
@MainActor
final class FileBrowserViewModel {
    private let root: URL
    private let service: any WorkspaceFileServicing

    private(set) var nodes: [FileNode] = []
    var selectedNode: FileNode?
    var content = ""
    var savedAt: Date?
    var isBinaryOrUnopenable: Bool = false
    var fileSizeString: String?
    private(set) var isLoading = false
    private(set) var isSaving = false
    private(set) var errorMessage: String?
    private(set) var message: String?

    var rootURL: URL { root }

    init(root: URL, service: any WorkspaceFileServicing = WorkspaceFileService()) {
        self.root = root
        self.service = service
    }

    func loadIfNeeded() async {
        guard nodes.isEmpty else { return }
        await refresh()
    }

    func refresh() async {
        fileScanLog.notice("FileBrowserViewModel.refresh: root=\(self.root.path, privacy: .public)")
        isLoading = true
        defer { isLoading = false }
        do {
            nodes = try await service.fileTree(at: root)
            errorMessage = nil
            if selectedNode == nil || !contains(node: selectedNode, in: nodes) {
                if let first = firstFile(in: nodes) {
                    await select(first)
                }
            }
        } catch {
            nodes = []
            errorMessage = error.localizedDescription
        }
    }

    private func contains(node: FileNode?, in list: [FileNode]) -> Bool {
        guard let node else { return false }
        for item in list {
            if item.id == node.id { return true }
            if let children = item.children, contains(node: node, in: children) {
                return true
            }
        }
        return false
    }

    private func firstFile(in list: [FileNode]) -> FileNode? {
        if let readme = list.first(where: { !$0.isDirectory && $0.name.lowercased().hasPrefix("readme") }) {
            return readme
        }
        for item in list {
            if !item.isDirectory { return item }
            if let children = item.children, let child = firstFile(in: children) {
                return child
            }
        }
        return nil
    }

    func select(_ node: FileNode) async {
        guard !node.isDirectory else { return }
        
        // Check for unsaved changes before switching
        if let currentNode = selectedNode, currentNode != node, !isBinaryOrUnopenable, content != "" {
            let fileManager = FileManager.default
            if let attributes = try? fileManager.attributesOfItem(atPath: currentNode.url.path),
               let modificationDate = attributes[.modificationDate] as? Date,
               let savedAt,
               modificationDate <= savedAt {
                // Content appears unchanged, safe to switch
            } else {
                await save()
            }
        }

        let fileManager = FileManager.default
        let attributes = try? fileManager.attributesOfItem(atPath: node.url.path)
        if let size = attributes?[.size] as? Int64 {
            fileSizeString = ByteCountFormatter.string(fromByteCount: size, countStyle: .file)
        } else {
            fileSizeString = nil
        }
        if let modificationDate = attributes?[.modificationDate] as? Date {
            savedAt = modificationDate
        }

        let ext = node.url.pathExtension.lowercased()
        let binaryExtensions: Set<String> = [
            "png", "jpg", "jpeg", "gif", "webp", "ico", "bmp", "tiff", "heic", "icns",
            "mp4", "mov", "mkv", "webm", "avi", "mp3", "wav", "m4a", "flac", "aac",
            "pdf", "zip", "tar", "gz", "tgz", "7z", "rar", "dmg", "pkg",
            "dylib", "so", "a", "o", "exe", "dll", "bin", "sqlite", "db", "sqlite3",
            "car", "nib", "storyboardc", "ttf", "otf", "woff", "woff2", "eot", "xcassets"
        ]

        if binaryExtensions.contains(ext) {
            content = ""
            selectedNode = node
            isBinaryOrUnopenable = true
            errorMessage = nil
            message = nil
            return
        }
        
        do {
            content = try await service.readText(at: node.url)
            selectedNode = node
            isBinaryOrUnopenable = false
            errorMessage = nil
            message = nil
        } catch {
            content = ""
            selectedNode = node
            isBinaryOrUnopenable = true
            errorMessage = nil
            message = nil
        }
    }

    func save() async {
        guard let selectedNode, !selectedNode.isDirectory else { return }
        
        // Check for write conflict: if the file was modified since we opened it
        let fileManager = FileManager.default
        let currentAttributes = try? fileManager.attributesOfItem(atPath: selectedNode.url.path)
        let currentModificationDate = currentAttributes?[.modificationDate] as? Date
        
        if let savedAt, let currentModificationDate,
           currentModificationDate > savedAt
        {
            message = "File was modified outside this app — changes may be lost"
            isSaving = false
            return
        }
        
        isSaving = true
        defer { isSaving = false }
        do {
            try await service.writeText(content, to: selectedNode.url)
            savedAt = Date()
            message = "Saved"
            errorMessage = nil
        } catch {
            message = nil
            errorMessage = "Could not save \(selectedNode.name): \(error.localizedDescription)"
        }
    }
}

@Observable
@MainActor
final class RulesPanelViewModel {
    private let root: URL
    private let service: any WorkspaceFileServicing

    private(set) var entries: [RuleFileEntry] = []
    var selectedEntry: RuleFileEntry?
    var content = ""
    var savedAt: Date?
    private(set) var isLoading = false
    private(set) var isSaving = false
    private(set) var message: String?

    var rootURL: URL { root }

    init(root: URL, service: any WorkspaceFileServicing = WorkspaceFileService()) {
        self.root = root
        self.service = service
    }

    func load() async {
        fileScanLog.notice("RulesPanelViewModel.load: root=\(self.root.path, privacy: .public)")
        isLoading = true
        defer { isLoading = false }
        do {
            entries = try await service.instructionFiles(in: root)
            message = nil
        } catch {
            entries = []
            message = error.localizedDescription
        }
    }

    func select(_ entry: RuleFileEntry) async {
        do {
            content = try await service.readText(at: entry.url)
            let fileManager = FileManager.default
            if let attributes = try? fileManager.attributesOfItem(atPath: entry.url.path),
               let modificationDate = attributes[.modificationDate] as? Date {
                savedAt = modificationDate
            }
            selectedEntry = entry
            message = nil
        } catch {
            message = "Could not open \(entry.relativePath): \(error.localizedDescription)"
        }
    }

    func save() async {
        guard let selectedEntry else { return }
        
        // Check for write conflict: if the file was modified since we opened it
        let fileManager = FileManager.default
        let currentAttributes = try? fileManager.attributesOfItem(atPath: selectedEntry.url.path)
        let currentModificationDate = currentAttributes?[.modificationDate] as? Date
        
        if let savedAt, let currentModificationDate,
           currentModificationDate > savedAt
        {
            message = "File was modified outside this app — changes may be lost"
            isSaving = false
            return
        }
        
        isSaving = true
        defer { isSaving = false }
        do {
            try await service.writeText(content, to: selectedEntry.url)
            savedAt = Date()
            message = "Saved"
        } catch {
            message = "Could not save: \(error.localizedDescription)"
        }
    }
}

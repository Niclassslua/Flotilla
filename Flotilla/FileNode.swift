import Foundation
import Observation
import os

/// Traces every filesystem scan Flotilla performs, so a "why did macOS just
/// ask for my X folder" report can be root-caused from a Console.app filter
/// on subsystem `com.niclassslua.flotilla` / category `FileScan`, instead of
/// guessed at from source.
let fileScanLog = Logger(subsystem: "com.niclassslua.flotilla", category: "FileScan")

struct FileNode: Identifiable, Hashable, Sendable {
    let url: URL
    let isDirectory: Bool
    let children: [FileNode]?

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

public struct SkillEntry: Identifiable, Hashable, Sendable {
    public let url: URL              // the SKILL.md
    public let name: String          // frontmatter `name`, else directory name
    public let description: String   // frontmatter `description`
    public let scope: SkillScope     // .global | .project
    public let source: String?       // plugin name when under ~/.claude/plugins
    public var id: URL { url }

    public init(
        url: URL,
        name: String,
        description: String,
        scope: SkillScope,
        source: String? = nil
    ) {
        self.url = url
        self.name = name
        self.description = description
        self.scope = scope
        self.source = source
    }
}

public enum SkillScope: String, Sendable, Hashable {
    case global
    case project
}

public enum SkillFrontmatter {
    public static func parse(_ text: String) -> (name: String?, description: String?) {
        let normalized = text
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        let lines = normalized.components(separatedBy: "\n")

        guard let first = lines.first, first.trimmingCharacters(in: .whitespaces) == "---" else {
            return (nil, nil)
        }

        var name: String?
        var description: String?

        var i = 1
        var currentKey: String?
        var currentValue: [String] = []

        func flushCurrent() {
            guard let key = currentKey else { return }
            let combined = currentValue.joined(separator: " ").trimmingCharacters(in: .whitespaces)
            let unquoted = stripQuotes(combined)
            if key == "name" {
                name = unquoted
            } else if key == "description" {
                description = unquoted
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

            if line.hasPrefix(" ") || line.hasPrefix("\t") {
                if currentKey != nil {
                    currentValue.append(trimmed)
                }
            } else if let colonIdx = line.firstIndex(of: ":") {
                flushCurrent()
                let key = String(line[..<colonIdx]).trimmingCharacters(in: .whitespaces)
                let val = String(line[line.index(after: colonIdx)...]).trimmingCharacters(in: .whitespaces)
                currentKey = key
                if !val.isEmpty && val != ">" && val != "|" {
                    currentValue.append(val)
                }
            }
            i += 1
        }

        guard hasClosed else { return (nil, nil) }
        return (name, description)
    }

    private static func stripQuotes(_ s: String) -> String {
        var str = s.trimmingCharacters(in: .whitespaces)
        if (str.hasPrefix("\"") && str.hasSuffix("\"")) || (str.hasPrefix("'") && str.hasSuffix("'")) {
            str = String(str.dropFirst().dropLast())
        }
        return str
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
            options: [.skipsHiddenFiles]
        )
        return try entries
            .filter { !excludedDirectories.contains($0.lastPathComponent) && !isTCCProtected($0) }
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

        let instructionNames = Set(["CLAUDE.md", "AGENTS.md", "GEMINI.md", "SKILL.md"])
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
            guard values.isRegularFile == true, url.pathExtension.lowercased() == "md" else { continue }

            let canonicalURL = url.resolvingSymlinksInPath().standardizedFileURL
            let rootPrefix = canonicalRoot.path.hasSuffix("/") ? canonicalRoot.path : canonicalRoot.path + "/"
            guard canonicalURL.path.hasPrefix(rootPrefix) else { continue }
            let relative = String(canonicalURL.path.dropFirst(rootPrefix.count))
            let isKnownInstruction = instructionNames.contains(url.lastPathComponent)
            let isSkill = relative.contains(".claude/skills/")
                || relative.contains(".agents/skills/")
                || relative.contains(".codex/skills/")
            guard isKnownInstruction || isSkill else { continue }
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
            (".codex", "AGENTS.md"),
            (".agents", "AGENTS.md"),
            (".gemini", "GEMINI.md"),
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

    /// Discovers skills across global (~/.claude, ~/.agents, ~/.codex) and project-scoped roots.
    private static func discoverSkills(
        projectRoot: URL,
        home: URL,
        fileManager: FileManager
    ) -> [SkillEntry] {
        var results: [SkillEntry] = []

        func scanDirectSkillRoots(baseDir: URL, relativePrefix: String, scope: SkillScope) {
            guard fileManager.fileExists(atPath: baseDir.path), !isTCCProtected(baseDir) else { return }
            fileScanLog.notice("discoverSkills: scanning direct root \(baseDir.path, privacy: .public)")
            guard let contents = try? fileManager.contentsOfDirectory(at: baseDir, includingPropertiesForKeys: [.isDirectoryKey]) else { return }

            for folder in contents {
                let isDir = (try? folder.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
                guard isDir else { continue }
                let skillFile = folder.appendingPathComponent("SKILL.md")
                if fileManager.fileExists(atPath: skillFile.path) {
                    let dirName = folder.lastPathComponent
                    let text = (try? String(contentsOf: skillFile, encoding: .utf8)) ?? ""
                    let parsed = SkillFrontmatter.parse(text)
                    results.append(SkillEntry(
                        url: skillFile,
                        name: parsed.name ?? dirName,
                        description: parsed.description ?? "",
                        scope: scope,
                        source: nil
                    ))
                }
            }
        }

        func scanPluginSkillRoots(pluginsDir: URL, scope: SkillScope) {
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
                    let skillFile = folder.appendingPathComponent("SKILL.md")
                    if fileManager.fileExists(atPath: skillFile.path) {
                        let dirName = folder.lastPathComponent
                        let text = (try? String(contentsOf: skillFile, encoding: .utf8)) ?? ""
                        let parsed = SkillFrontmatter.parse(text)
                        results.append(SkillEntry(
                            url: skillFile,
                            name: parsed.name ?? dirName,
                            description: parsed.description ?? "",
                            scope: scope,
                            source: pluginName
                        ))
                    }
                }
            }
        }

        // Global skills
        scanDirectSkillRoots(baseDir: home.appendingPathComponent(".claude/skills"), relativePrefix: "~/.claude/skills", scope: .global)
        scanPluginSkillRoots(pluginsDir: home.appendingPathComponent(".claude/plugins"), scope: .global)
        scanDirectSkillRoots(baseDir: home.appendingPathComponent(".agents/skills"), relativePrefix: "~/.agents/skills", scope: .global)
        scanDirectSkillRoots(baseDir: home.appendingPathComponent(".codex/skills"), relativePrefix: "~/.codex/skills", scope: .global)

        // Project skills
        scanDirectSkillRoots(baseDir: projectRoot.appendingPathComponent(".claude/skills"), relativePrefix: ".claude/skills", scope: .project)
        scanPluginSkillRoots(pluginsDir: projectRoot.appendingPathComponent(".claude/plugins"), scope: .project)
        scanDirectSkillRoots(baseDir: projectRoot.appendingPathComponent(".agents/skills"), relativePrefix: ".agents/skills", scope: .project)
        scanDirectSkillRoots(baseDir: projectRoot.appendingPathComponent(".codex/skills"), relativePrefix: ".codex/skills", scope: .project)

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
    private(set) var isLoading = false
    private(set) var isSaving = false
    private(set) var errorMessage: String?
    private(set) var message: String?

    var rootURL: URL { root }

    init(root: URL, service: any WorkspaceFileServicing = WorkspaceFileService()) {
        self.root = root
        self.service = service
    }

    func refresh() async {
        fileScanLog.notice("FileBrowserViewModel.refresh: root=\(self.root.path, privacy: .public)")
        isLoading = true
        defer { isLoading = false }
        do {
            nodes = try await service.fileTree(at: root)
            errorMessage = nil
        } catch {
            nodes = []
            errorMessage = error.localizedDescription
        }
    }

    func select(_ node: FileNode) async {
        guard !node.isDirectory else { return }
        
        // Check for unsaved changes before switching
        if let currentNode = selectedNode, currentNode != node, content != "" {
            let fileManager = FileManager.default
            if let attributes = try? fileManager.attributesOfItem(atPath: currentNode.url.path),
               let modificationDate = attributes[.modificationDate] as? Date,
               let savedAt,
               modificationDate <= savedAt {
                // Content appears unchanged, safe to switch
            } else {
                // Prompt user about unsaved changes - for now, save automatically
                // In a full implementation, this would show a confirmation dialog
                await save()
            }
        }
        
        do {
            content = try await service.readText(at: node.url)
            let fileManager = FileManager.default
            if let attributes = try? fileManager.attributesOfItem(atPath: node.url.path),
               let modificationDate = attributes[.modificationDate] as? Date {
                savedAt = modificationDate
            }
            selectedNode = node
            errorMessage = nil
            message = nil
        } catch {
            errorMessage = "Could not open \(node.name): \(error.localizedDescription)"
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

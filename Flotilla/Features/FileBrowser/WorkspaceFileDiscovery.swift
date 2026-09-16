import Foundation
import os

/// Traces every filesystem scan Flotilla performs, so a "why did macOS just
/// ask for my X folder" report can be root-caused from a Console.app filter
/// on subsystem `com.niclassslua.flotilla` / category `FileScan`, instead of
/// guessed at from source.
let fileScanLog = Logger(subsystem: "com.niclassslua.flotilla", category: "FileScan")

/// Filesystem traversal policies shared by workspace features.
enum WorkspaceFileDiscovery {
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

    static func loadChildren(
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

    static func discoverInstructionFiles(
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
            let canonicalURL = url.resolvingSymlinksInPath().standardizedFileURL
            let rootPrefix = canonicalRoot.path.hasSuffix("/") ? canonicalRoot.path : canonicalRoot.path + "/"
            guard canonicalURL.path.hasPrefix(rootPrefix) else { continue }
            let relative = String(canonicalURL.path.dropFirst(rootPrefix.count))
            // Filename must match a known instruction file (e.g. CLAUDE.md,
            // AGENTS.md) — being inside an AI-config directory is not
            // sufficient on its own, or any markdown file dropped in
            // .claude/ would be misidentified as a rules file.
            let isKnownInstruction = instructionNames.contains(filename)
            let isSkill = relative.contains(".claude/skills/")
                || relative.contains(".agents/skills/")
                || relative.contains(".codex/skills/")
                || relative.contains(".gemini/skills/")
                || relative.contains(".antigravity/skills/")

            guard isKnownInstruction || isSkill else { continue }
            results.append(RuleFileEntry(url: url, relativePath: relative, scope: .project))
        }
        return results.sorted { $0.relativePath.localizedStandardCompare($1.relativePath) == .orderedAscending }
    }

    /// Scans well-known global rule file locations. Non-recursive, existence-only
    /// checks — no enumerator, so no TCC surprises.
    static func discoverGlobalInstructionFiles(
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
    static func discoverSkills(
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


import Foundation
import Observation

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

    var id: URL { url }
    var name: String { relativePath }
}

protocol WorkspaceFileServicing: Sendable {
    func fileTree(at root: URL) async throws -> [FileNode]
    func instructionFiles(in root: URL) async throws -> [RuleFileEntry]
    func readText(at url: URL) async throws -> String
    func writeText(_ text: String, to url: URL) async throws
}

struct WorkspaceFileService: WorkspaceFileServicing {
    init() {}

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

    private static let excludedDirectories = Set([
        ".git", ".build", "DerivedData", "node_modules", "Pods", ".swiftpm"
    ])

    private static func loadChildren(
        of directory: URL,
        depth: Int,
        fileManager: FileManager
    ) throws -> [FileNode] {
        guard depth < 8 else { return [] }
        let entries = try fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
            options: [.skipsHiddenFiles]
        )
        return try entries
            .filter { !excludedDirectories.contains($0.lastPathComponent) }
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
        guard let enumerator = fileManager.enumerator(
            at: root,
            includingPropertiesForKeys: keys,
            options: [.skipsPackageDescendants],
            errorHandler: { _, _ in true }
        ) else { return [] }

        let instructionNames = Set(["CLAUDE.md", "AGENTS.md", "GEMINI.md", "SKILL.md"])
        var results: [RuleFileEntry] = []
        for case let url as URL in enumerator {
            let values = try url.resourceValues(forKeys: Set(keys))
            if values.isSymbolicLink == true {
                if values.isDirectory == true { enumerator.skipDescendants() }
                continue
            }
            if values.isDirectory == true, excludedDirectories.contains(url.lastPathComponent) {
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
            results.append(RuleFileEntry(url: url, relativePath: relative))
        }
        return results.sorted { $0.relativePath.localizedStandardCompare($1.relativePath) == .orderedAscending }
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
    private(set) var isLoading = false
    private(set) var isSaving = false
    private(set) var errorMessage: String?
    private(set) var message: String?

    init(root: URL, service: any WorkspaceFileServicing = WorkspaceFileService()) {
        self.root = root
        self.service = service
    }

    func refresh() async {
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
        do {
            content = try await service.readText(at: node.url)
            selectedNode = node
            errorMessage = nil
            message = nil
        } catch {
            errorMessage = "Could not open \(node.name): \(error.localizedDescription)"
        }
    }

    func save() async {
        guard let selectedNode, !selectedNode.isDirectory else { return }
        isSaving = true
        defer { isSaving = false }
        do {
            try await service.writeText(content, to: selectedNode.url)
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
    private(set) var isLoading = false
    private(set) var isSaving = false
    private(set) var message: String?

    init(root: URL, service: any WorkspaceFileServicing = WorkspaceFileService()) {
        self.root = root
        self.service = service
    }

    func load() async {
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
            selectedEntry = entry
            message = nil
        } catch {
            message = "Could not open \(entry.relativePath): \(error.localizedDescription)"
        }
    }

    func save() async {
        guard let selectedEntry else { return }
        isSaving = true
        defer { isSaving = false }
        do {
            try await service.writeText(content, to: selectedEntry.url)
            message = "Saved"
        } catch {
            message = "Could not save: \(error.localizedDescription)"
        }
    }
}

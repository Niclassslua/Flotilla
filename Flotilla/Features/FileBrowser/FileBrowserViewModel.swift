import Foundation
import Observation
import os

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

    private(set) var loadedContent: String?
    var isDirty: Bool { !isBinaryOrUnopenable && loadedContent != nil && content != loadedContent }

    func select(_ node: FileNode) async {
        guard !node.isDirectory else { return }

        // Check for unsaved changes before switching
        if let currentNode = selectedNode, currentNode != node, isDirty {
            let outcome = await save()
            switch outcome {
            case .conflict, .failed:
                // Preserve unsaved edits; do not switch away from file on conflict or error
                return
            case .saved, .noChanges:
                break
            }
        }

        let metadata = await service.metadata(at: node.url)
        if let size = metadata.size {
            fileSizeString = ByteCountFormatter.string(fromByteCount: size, countStyle: .file)
        } else {
            fileSizeString = nil
        }
        if let modificationDate = metadata.modificationDate {
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
            loadedContent = nil
            selectedNode = node
            isBinaryOrUnopenable = true
            errorMessage = nil
            message = nil
            return
        }

        do {
            let text = try await service.readText(at: node.url)
            content = text
            loadedContent = text
            selectedNode = node
            isBinaryOrUnopenable = false
            errorMessage = nil
            message = nil
        } catch {
            content = ""
            loadedContent = nil
            selectedNode = node
            isBinaryOrUnopenable = true
            errorMessage = nil
            message = nil
        }
    }

    enum SaveOutcome: Sendable {
        case saved
        case noChanges
        case conflict(String)
        case failed(String)
    }

    @discardableResult
    func save() async -> SaveOutcome {
        guard let selectedNode, !selectedNode.isDirectory else { return .noChanges }
        guard !isBinaryOrUnopenable else { return .noChanges }
        guard content != loadedContent else { return .noChanges }

        // Check for write conflict: if the file was modified since we opened it
        let metadata = await service.metadata(at: selectedNode.url)
        let currentModificationDate = metadata.modificationDate

        if let savedAt, let currentModificationDate,
           currentModificationDate > savedAt
        {
            let conflictMsg = "File was modified outside this app — changes may be lost"
            message = conflictMsg
            isSaving = false
            return .conflict(conflictMsg)
        }

        isSaving = true
        defer { isSaving = false }
        do {
            try await service.writeText(content, to: selectedNode.url)
            let updatedMeta = await service.metadata(at: selectedNode.url)
            savedAt = updatedMeta.modificationDate ?? Date()
            loadedContent = content
            message = "Saved"
            errorMessage = nil
            return .saved
        } catch {
            message = nil
            let err = "Could not save \(selectedNode.name): \(error.localizedDescription)"
            errorMessage = err
            return .failed(err)
        }
    }
}

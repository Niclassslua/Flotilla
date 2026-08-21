import Foundation
import Observation
import SwiftUI

enum KnowledgeFilter: String, Sendable, Hashable, CaseIterable {
    case all, global, project

    var label: String {
        switch self {
        case .all: return "All"
        case .global: return "Global"
        case .project: return "Project"
        }
    }
}

/// How the catalog is ordered. Each design applies this within whatever
/// grouping it imposes — Ledger and Shelf still separate global from project
/// first, then order inside each group.
enum KnowledgeSort: String, Sendable, Hashable, CaseIterable, Identifiable {
    case name
    case modified
    case size

    var id: String { rawValue }

    var label: String {
        switch self {
        case .name: return "Name"
        case .modified: return "Last Modified"
        case .size: return "Size"
        }
    }

    var symbolName: String {
        switch self {
        case .name: return "textformat"
        case .modified: return "clock"
        case .size: return "internaldrive"
        }
    }
}

/// Loads and edits the instruction files behind both the Skills and Rules tabs.
///
/// Replaces the two near-identical view models these tabs used to carry
/// (`ProjectSkillsViewModel` / `ProjectRulesViewModel`); `kind` is the only
/// thing that differed between them, and it only changes which
/// `WorkspaceFileServicing` calls `load()` makes.
@Observable
@MainActor
final class ProjectKnowledgeViewModel {
    let kind: KnowledgeKind
    let projectRoot: URL
    private let service: any WorkspaceFileServicing

    private(set) var items: [KnowledgeItem] = []
    var selected: KnowledgeItem?
    var content = ""
    var savedAt: Date?
    var filter: KnowledgeFilter = .all
    var sort: KnowledgeSort = .name
    var searchText = ""
    private(set) var isLoading = false
    private(set) var isSaving = false
    private(set) var message: String?

    init(
        kind: KnowledgeKind,
        projectRoot: URL,
        service: any WorkspaceFileServicing = WorkspaceFileService()
    ) {
        self.kind = kind
        self.projectRoot = projectRoot
        self.service = service
    }

    // MARK: - Loading

    func load() async {
        fileScanLog.notice("ProjectKnowledgeViewModel.load: kind=\(self.kind.rawValue, privacy: .public) root=\(self.projectRoot.path, privacy: .public)")
        isLoading = true
        defer { isLoading = false }
        do {
            switch kind {
            case .skills:
                items = try await service.skills(projectRoot: projectRoot).map(KnowledgeItem.init(skill:))
            case .rules:
                // Globals first, matching the order this tab has always shown.
                let projectEntries = try await service.instructionFiles(in: projectRoot)
                let globalEntries = try await service.globalInstructionFiles()
                items = (globalEntries + projectEntries).map(KnowledgeItem.init(rule:))
            }
            message = nil
        } catch {
            items = []
            message = error.localizedDescription
        }
    }

    // MARK: - Filtering

    /// Scope filter first, then a free-text match across every field a user
    /// might reasonably remember an item by, then the chosen ordering.
    var filteredItems: [KnowledgeItem] {
        let scoped: [KnowledgeItem] = switch filter {
        case .all: items
        case .global: items.filter { $0.scope == .global }
        case .project: items.filter { $0.scope == .project }
        }

        let query = searchText.trimmingCharacters(in: .whitespaces)
        let matched = query.isEmpty ? scoped : scoped.filter { $0.matches(query) }

        return matched.sorted(by: sort.areInIncreasingOrder)
    }

    // MARK: - Editing

    func select(_ item: KnowledgeItem) async {
        do {
            content = try await service.readText(at: item.url)
            if let attributes = try? FileManager.default.attributesOfItem(atPath: item.url.path),
               let modificationDate = attributes[.modificationDate] as? Date {
                savedAt = modificationDate
            }
            selected = item
            message = nil
        } catch {
            message = "Could not open \(item.title): \(error.localizedDescription)"
        }
    }

    func deselect() {
        selected = nil
        content = ""
        message = nil
    }

    func save() async {
        guard let selected else { return }

        // Refuse to clobber an edit made outside the app since we read the
        // file. The user gets told rather than silently losing the other change.
        let currentAttributes = try? FileManager.default.attributesOfItem(atPath: selected.url.path)
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
            try await service.writeText(content, to: selected.url)
            savedAt = Date()
            message = "Saved"
        } catch {
            message = "Could not save: \(error.localizedDescription)"
        }
    }

    /// Writes a starter rules file into the project root and opens it. If the
    /// file already exists we just reload and open it rather than overwriting
    /// whatever the user has already written there.
    /// - Returns: `true` when a new file was actually created.
    @discardableResult
    func createTemplate(named fileName: String, content template: String) async -> Bool {
        let targetURL = projectRoot.appendingPathComponent(fileName)
        let existed = FileManager.default.fileExists(atPath: targetURL.path)

        if !existed {
            do {
                try template.write(to: targetURL, atomically: true, encoding: .utf8)
            } catch {
                message = "Could not create \(fileName): \(error.localizedDescription)"
                return false
            }
        }

        await load()
        if let item = items.first(where: { $0.url == targetURL }) {
            await select(item)
        }
        return !existed
    }
}

extension KnowledgeSort {
    /// Name sorts A–Z; the other two put the most interesting end first —
    /// freshest edits and biggest documents — since that is what someone
    /// switching away from alphabetical is looking for.
    func areInIncreasingOrder(_ lhs: KnowledgeItem, _ rhs: KnowledgeItem) -> Bool {
        switch self {
        case .name:
            return lhs.title.localizedStandardCompare(rhs.title) == .orderedAscending
        case .modified:
            // Never-modified items sort last rather than jumbling with the oldest.
            switch (lhs.lastModified, rhs.lastModified) {
            case let (l?, r?): return l > r
            case (nil, _?): return false
            case (_?, nil): return true
            case (nil, nil): return lhs.title.localizedStandardCompare(rhs.title) == .orderedAscending
            }
        case .size:
            guard lhs.byteSize != rhs.byteSize else {
                return lhs.title.localizedStandardCompare(rhs.title) == .orderedAscending
            }
            return lhs.byteSize > rhs.byteSize
        }
    }
}

extension KnowledgeItem {
    /// Case-insensitive match over every user-visible field. The union of what
    /// the Skills and Rules tabs each used to search on their own.
    func matches(_ query: String) -> Bool {
        if title.localizedCaseInsensitiveContains(query) { return true }
        if subtitle.localizedCaseInsensitiveContains(query) { return true }
        if let source, source.localizedCaseInsensitiveContains(query) { return true }
        if let frameworkName, frameworkName.localizedCaseInsensitiveContains(query) { return true }
        if let version, version.localizedCaseInsensitiveContains(query) { return true }
        if let invocation, invocation.localizedCaseInsensitiveContains(query) { return true }
        if parentFolder.localizedCaseInsensitiveContains(query) { return true }
        return tags.contains { $0.localizedCaseInsensitiveContains(query) }
    }
}

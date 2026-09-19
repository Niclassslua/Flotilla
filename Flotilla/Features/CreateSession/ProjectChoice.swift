import Foundation
import SwiftUI
import SessionKit

/// Where a session will run. Replaces the old `isGeneralSession: Bool` +
/// `selectedFolder: URL?` pair, which could represent the nonsense state
/// "project session with no folder".
///
/// `known` is a project `AppStore` already tracks; `custom` is a folder picked
/// or dropped that isn't a project yet. `AppStore.createSession` treats both
/// the same — it finds-or-creates a `Project` for whatever `rootPath` it gets —
/// so the distinction only matters for how the picker presents them.
enum ProjectChoice: Hashable, Identifiable {
    case general
    case known(Project)
    case custom(URL)

    var id: String {
        switch self {
        case .general: "general"
        case .known(let project): project.id.uuidString
        case .custom(let url): url.path
        }
    }

    /// The argument `AppStore.createSession(projectFolder:)` wants: `nil` for a
    /// general session.
    var folder: URL? {
        switch self {
        case .general: nil
        case .known(let project): project.rootPath
        case .custom(let url): url
        }
    }

    var displayName: String {
        switch self {
        case .general: "General session"
        case .known(let project): project.name
        case .custom(let url): url.lastPathComponent
        }
    }

    /// Abbreviated with `~` — these paths are long and the home prefix carries
    /// no information for a local-only tool.
    var displayPath: String? {
        guard let folder else { return nil }
        return folder.path.replacingOccurrences(
            of: FileManager.default.homeDirectoryForCurrentUser.path,
            with: "~"
        )
    }

    var isGeneral: Bool {
        if case .general = self { return true }
        return false
    }

    var symbolName: String {
        switch self {
        case .general: "sparkles"
        case .known: "folder.fill"
        case .custom: "folder.badge.plus"
        }
    }
}

// MARK: - Candidate list

enum ProjectChoiceCatalog {
    /// Known projects ordered by their most recently active session —
    /// `Project` carries no timestamp of its own, so recency has to be
    /// derived from its sessions. The list
    /// reorders as work moves, which is the whole point: the repo you touched
    /// last is the one you almost certainly want next.
    @MainActor
    static func recentChoices(store: AppStore, limit: Int? = nil) -> [ProjectChoice] {
        let ordered = store.projects
            .sorted { lhs, rhs in
                let lhsDate = store.sessions(for: lhs).map(\.lastActiveAt).max() ?? .distantPast
                let rhsDate = store.sessions(for: rhs).map(\.lastActiveAt).max() ?? .distantPast
                if lhsDate == rhsDate { return lhs.name < rhs.name }
                return lhsDate > rhsDate
            }
        let limited = limit.map { Array(ordered.prefix($0)) } ?? ordered
        return limited.map { ProjectChoice.known($0) }
    }

    /// Case- and diacritic-insensitive substring match over both the display
    /// name and the path, so "flot" and "~/Projects/Swift" both find the same
    /// repo.
    static func filter(_ choices: [ProjectChoice], query: String) -> [ProjectChoice] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return choices }
        return choices.filter { choice in
            let haystack = [choice.displayName, choice.displayPath ?? ""].joined(separator: " ")
            return haystack.range(of: trimmed, options: [.caseInsensitive, .diacriticInsensitive]) != nil
        }
    }
}

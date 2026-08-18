import Foundation
import Observation
import SessionKit
import SwiftUI

@Observable
@MainActor
final class WorkspaceNavigator {
    var selection: SidebarItem = .allSessions
    var presentation: WorkspacePresentation = .grid
    var inspectorTab: InspectorTab = .changes
    var isInspectorOpen = false
    var presentedSheet: WorkspaceSheet?
    var columnVisibility: NavigationSplitViewVisibility = .all
    var searchText = ""

    // Legacy compatibility - one-way flow from navigator to store
    var selectedSessionID: UUID? {
        get {
            if case .session(let id) = selection { return id }
            return nil
        }
        set {
            if let newValue { selection = .session(newValue) }
        }
    }

    var selectedProjectID: UUID? {
        get {
            if case .project(let id) = selection { return id }
            return nil
        }
        set {
            if let newValue { selection = .project(newValue) }
        }
    }

    // Legacy - not used in new architecture
    var destination: AppDestination {
        get {
            switch selection {
            case .overview: return .overview
            case .allSessions, .session: return .sessions
            case .allProjects, .project: return .projects
            }
        }
        set {
            switch newValue {
            case .overview: selection = .overview
            case .sessions: selection = .allSessions
            case .projects: selection = .allProjects
            }
        }
    }

    var layout: WorkspaceLayout {
        get {
            switch presentation {
            case .focus: return .focus
            case .grid: return .grid
            case .board: return .board
            case .list: return .list
            }
        }
        set {
            switch newValue {
            case .focus: presentation = .focus
            case .grid: presentation = .grid
            case .board: presentation = .board
            case .list: presentation = .list
            }
        }
    }

    var sessionLens: SessionLens = .terminal
    var projectLens: ProjectLens = .overview
    var isChangesInspectorOpen: Bool = false

    nonisolated init() {}
}

private struct WorkspaceNavigatorKey: EnvironmentKey {
    static let defaultValue: WorkspaceNavigator = {
        WorkspaceNavigator()
    }()
}

extension EnvironmentValues {
    var workspaceNavigator: WorkspaceNavigator {
        get { self[WorkspaceNavigatorKey.self] }
        set { self[WorkspaceNavigatorKey.self] = newValue }
    }
}

enum SidebarItem: Hashable, Codable, Sendable {
    case overview
    case allSessions
    case allProjects
    case project(UUID)
    case session(UUID)

    var title: String {
        switch self {
        case .overview: return "Overview"
        case .allSessions: return "All Sessions"
        case .allProjects: return "All Projects"
        case .project: return "Project"
        case .session: return "Session"
        }
    }

    var systemImage: String {
        switch self {
        case .overview: return "house"
        case .allSessions: return "terminal"
        case .allProjects: return "folder"
        case .project: return "folder.fill"
        case .session: return "terminal.fill"
        }
    }
}

enum WorkspacePresentation: String, CaseIterable, Identifiable, Codable, Sendable {
    case grid
    case board
    case list
    case focus

    var id: Self { self }

    var title: String {
        switch self {
        case .grid: return "Grid"
        case .board: return "Board"
        case .list: return "List"
        case .focus: return "Focus"
        }
    }

    var systemImage: String {
        switch self {
        case .grid: return "square.grid.2x2"
        case .board: return "square.grid.2x2.fill"
        case .list: return "list.bullet"
        case .focus: return "macwindow"
        }
    }
}

enum InspectorTab: String, CaseIterable, Identifiable, Codable, Sendable {
    case changes
    case files
    case instructions
    case details

    var id: Self { self }

    var title: String {
        switch self {
        case .changes: return "Changes"
        case .files: return "Files"
        case .instructions: return "Instructions"
        case .details: return "Details"
        }
    }

    var systemImage: String {
        switch self {
        case .changes: return "arrow.triangle.branch"
        case .files: return "folder"
        case .instructions: return "doc.badge.gearshape"
        case .details: return "info.circle"
        }
    }
}

enum WorkspaceSheet: Identifiable, Equatable, Codable, Sendable {
    case createSession
    case commandPalette
    case shortcuts
    case restore
    case deleteSession(UUID)

    var id: String {
        switch self {
        case .createSession: "create-session"
        case .commandPalette: "command-palette"
        case .shortcuts: "shortcuts"
        case .restore: "restore"
        case .deleteSession(let id): "delete-session-\(id)"
        }
    }
}

enum AppDestination: String, CaseIterable, Identifiable, Codable, Sendable {
    case overview
    case sessions
    case projects

    var id: Self { self }

    var title: String {
        switch self {
        case .overview: return "Overview"
        case .sessions: return "Sessions"
        case .projects: return "Projects"
        }
    }

    var systemImage: String {
        switch self {
        case .overview: return "house"
        case .sessions: return "terminal"
        case .projects: return "folder"
        }
    }
}

enum WorkspaceLayout: String, CaseIterable, Identifiable, Codable, Sendable {
    case focus
    case grid
    case board
    case list

    var id: Self { self }

    var title: String {
        switch self {
        case .focus: return "Focus"
        case .grid: return "Grid"
        case .board: return "Board"
        case .list: return "List"
        }
    }

    var systemImage: String {
        switch self {
        case .focus: return "macwindow"
        case .grid: return "square.grid.2x2"
        case .board: return "square.grid.2x2.fill"
        case .list: return "list.bullet"
        }
    }
}

enum SessionLens: String, CaseIterable, Identifiable, Codable, Sendable {
    case terminal
    case files
    case instructions

    var id: Self { self }

    var title: String {
        switch self {
        case .terminal: return "Terminal"
        case .files: return "Files"
        case .instructions: return "Instructions"
        }
    }

    var systemImage: String {
        switch self {
        case .terminal: return "terminal"
        case .files: return "folder"
        case .instructions: return "doc.badge.gearshape"
        }
    }
}

enum ProjectLens: String, CaseIterable, Identifiable, Codable, Sendable {
    case overview
    case git
    case files
    case skills
    case rules

    var id: Self { self }
}
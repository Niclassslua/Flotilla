import Foundation
import Observation
import SessionKit
import SwiftUI

@Observable
@MainActor
final class WorkspaceNavigator {
    var destination: AppDestination = .overview
    var layout: WorkspaceLayout = .focus
    var sessionLens: SessionLens = .terminal
    var projectLens: ProjectLens = .overview
    var selectedSessionID: UUID?
    var selectedProjectID: UUID?
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

enum AppDestination: String, CaseIterable, Identifiable {
    case overview
    case sessions
    case projects

    var id: Self { self }

    var title: String {
        switch self {
        case .overview: "Overview"
        case .sessions: "Sessions"
        case .projects: "Projects"
        }
    }

    var systemImage: String {
        switch self {
        case .overview: "house"
        case .sessions: "terminal"
        case .projects: "folder"
        }
    }
}

enum WorkspaceLayout: String, CaseIterable, Identifiable {
    case focus
    case grid
    case board

    var id: Self { self }

    var title: String {
        switch self {
        case .focus: "Focus"
        case .grid: "Grid"
        case .board: "Board"
        }
    }

    var systemImage: String {
        switch self {
        case .focus: "rectangle.inset.filled"
        case .grid: "square.grid.2x2"
        case .board: "square.grid.2x2.fill"
        }
    }
}

enum SessionLens: String, CaseIterable, Identifiable {
    case terminal
    case files
    case instructions

    var id: Self { self }

    var title: String {
        switch self {
        case .terminal: "Terminal"
        case .files: "Files"
        case .instructions: "Instructions"
        }
    }

    var systemImage: String {
        switch self {
        case .terminal: "terminal"
        case .files: "folder"
        case .instructions: "doc.badge.gearshape"
        }
    }
}

enum ProjectLens: String, CaseIterable, Identifiable {
    case overview
    case changes
    case files
    case instructions

    var id: Self { self }

    var title: String {
        switch self {
        case .overview: "Overview"
        case .changes: "Changes"
        case .files: "Files"
        case .instructions: "Instructions"
        }
    }

    var systemImage: String {
        switch self {
        case .overview: "rectangle.grid.1x2"
        case .changes: "arrow.triangle.branch"
        case .files: "folder"
        case .instructions: "doc.badge.gearshape"
        }
    }
}
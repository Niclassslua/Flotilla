import Foundation
import SessionKit

// Shared navigation types are now in WorkspaceNavigator.swift
// This file only contains the command enum for the command palette

/// Where a command lands. Exists so the palette can be checked for two entries
/// that go to the same place — it shipped with two such pairs, which is how a
/// user ends up choosing between labels that do the same thing.
///
/// See `docs/ui-model.md` § 1 for the destination canon.
enum WorkspaceDestination: Hashable {
    /// The landing surface: attention, activity, projects.
    case home
    /// The session collection, in one of its presentations.
    case sessions(WorkspacePresentation)
    /// The currently selected session, full screen.
    case focusedSession
    /// A project-owned panel scoped to the selected session.
    case sessionPanel(ProjectDetailView.ProjectTab)
}

enum WorkspaceCommand: String, CaseIterable, Identifiable {
    case newSession
    case newSessionFromIssue
    case showHome
    case showSessions
    case showGrid
    case showBoard
    case showTerminal
    case showFiles
    case showInstructions
    case showChanges
    case restoreSessions
    case showSettings
    case showShortcuts

    var id: Self { self }

    /// `nil` for commands that perform an action rather than navigating.
    /// Every non-nil value must be unique across `allCases` — asserted by
    /// `WorkspaceCommandTests.testNoTwoCommandsShareADestination`.
    var destination: WorkspaceDestination? {
        switch self {
        case .newSession, .newSessionFromIssue, .restoreSessions, .showSettings, .showShortcuts: nil
        case .showHome: .home
        case .showSessions: .sessions(.focus)
        case .showGrid: .sessions(.grid)
        case .showBoard: .sessions(.board)
        case .showTerminal: .focusedSession
        case .showFiles: .sessionPanel(.files)
        case .showInstructions: .sessionPanel(.rules)
        case .showChanges: .sessionPanel(.git)
        }
    }

    var title: String {
        switch self {
        case .newSession: "New session"
        case .newSessionFromIssue: "New session from issue"
        case .showHome: "Go to Home"
        case .showSessions: "Go to Sessions"
        case .showGrid: "Show session grid"
        case .showBoard: "Show Kanban board"
        case .showTerminal: "Open Terminal"
        case .showFiles: "Browse project files"
        case .showInstructions: "View instructions"
        case .showChanges: "Review changes"
        case .restoreSessions: "Restore stopped sessions"
        case .showSettings: "Open Settings"
        case .showShortcuts: "Keyboard shortcuts"
        }
    }

    var subtitle: String {
        switch self {
        case .newSession: "Launch an agent in a checkout or worktree"
        case .newSessionFromIssue: "Start from one of the project's open GitHub issues"
        case .showHome: "Attention, activity and projects"
        case .showSessions: "Every running agent"
        case .showGrid: "Tile every live terminal"
        case .showBoard: "Visualize sessions on a Kanban board"
        case .showTerminal: "Focus the selected session's terminal"
        case .showFiles: "Open the selected worktree's file editor"
        case .showInstructions: "View all instruction documents"
        case .showChanges: "Review Git changes"
        case .restoreSessions: "Restart finished or crashed sessions"
        case .showSettings: "Configure agents, sessions, and worktrees"
        case .showShortcuts: "Reference for navigation and session commands"
        }
    }

    var systemImage: String {
        switch self {
        case .newSession: "plus"
        case .newSessionFromIssue: "number"
        case .showHome: "house"
        case .showSessions: "square.stack.3d.up"
        case .showGrid: "square.grid.2x2"
        case .showBoard: "square.grid.2x2.fill"
        case .showTerminal: "terminal"
        case .showFiles: "folder"
        case .showInstructions: "doc.badge.gearshape"
        case .showChanges: "arrow.triangle.branch"
        case .restoreSessions: "arrow.clockwise"
        case .showSettings: "gearshape"
        case .showShortcuts: "keyboard"
        }
    }
}

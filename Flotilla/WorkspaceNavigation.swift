import Foundation
import SessionKit

// Shared navigation types are now in WorkspaceNavigator.swift
// This file only contains the command enum for the command palette

enum WorkspaceSheet: Identifiable {
    case createSession
    case commandPalette
    case shortcuts
    case restore

    var id: String {
        switch self {
        case .createSession: "create-session"
        case .commandPalette: "command-palette"
        case .shortcuts: "shortcuts"
        case .restore: "restore"
        }
    }
}

enum WorkspaceCommand: String, CaseIterable, Identifiable {
    case newSession
    case showOverview
    case showProjects
    case showSessions
    case showGrid
    case showBoard
    case showTerminal
    case showFiles
    case showInstructions
    case showChanges
    case restoreSessions
    case showSettings

    var id: Self { self }

    var title: String {
        switch self {
        case .newSession: "New session"
        case .showOverview: "Go to Overview"
        case .showProjects: "Go to Projects"
        case .showSessions: "Go to Sessions"
        case .showGrid: "Show session grid"
        case .showBoard: "Show Kanban board"
        case .showTerminal: "Open Terminal"
        case .showFiles: "Browse project files"
        case .showInstructions: "View instructions"
        case .showChanges: "Review changes"
        case .restoreSessions: "Restore stopped sessions"
        case .showSettings: "Open Settings"
        }
    }

    var subtitle: String {
        switch self {
        case .newSession: "Launch an agent in a checkout or worktree"
        case .showOverview: "Open the goal-first launch dashboard"
        case .showProjects: "Browse local project workspaces"
        case .showSessions: "Return to active session focus"
        case .showGrid: "Tile every live terminal"
        case .showBoard: "Visualize sessions on a Kanban board"
        case .showTerminal: "Focus the selected session's terminal"
        case .showFiles: "Open the selected worktree's file editor"
        case .showInstructions: "View all instruction documents"
        case .showChanges: "Toggle Git changes inspector"
        case .restoreSessions: "Restart finished or crashed sessions"
        case .showSettings: "Configure agents, worktrees, and appearance"
        }
    }

    var systemImage: String {
        switch self {
        case .newSession: "plus"
        case .showOverview: "house"
        case .showProjects: "folder"
        case .showSessions: "terminal"
        case .showGrid: "square.grid.2x2"
        case .showBoard: "square.grid.2x2.fill"
        case .showTerminal: "terminal"
        case .showFiles: "folder"
        case .showInstructions: "doc.badge.gearshape"
        case .showChanges: "arrow.triangle.branch"
        case .restoreSessions: "arrow.clockwise"
        case .showSettings: "gearshape"
        }
    }
}
import Foundation

extension Notification.Name {
    static let flotillaNewSession = Notification.Name("Flotilla.NewSession")
    static let flotillaCommandPalette = Notification.Name("Flotilla.CommandPalette")
    static let flotillaShowProjects = Notification.Name("Flotilla.ShowProjects")
    static let flotillaShowSessions = Notification.Name("Flotilla.ShowSessions")
    static let flotillaShowGrid = Notification.Name("Flotilla.ShowGrid")
}

enum AppDestination: String, CaseIterable, Identifiable {
    case home
    case projects
    case sessions

    var id: Self { self }

    var title: String {
        switch self {
        case .home: "Home"
        case .projects: "Projects"
        case .sessions: "Sessions"
        }
    }

    var systemImage: String {
        switch self {
        case .home: "house"
        case .projects: "folder"
        case .sessions: "terminal"
        }
    }
}

enum WorkspaceViewMode: String, Equatable {
    case single
    case grid
}

enum SessionSurface: String, CaseIterable, Identifiable, Equatable {
    case terminal
    case git
    case files
    case rules
    case skills

    var id: Self { self }

    var title: String {
        switch self {
        case .terminal: "Terminal"
        case .git: "Diff"
        case .files: "Files"
        case .rules: "Rules"
        case .skills: "Skills"
        }
    }

    var systemImage: String {
        switch self {
        case .terminal: "terminal"
        case .git: "plusminus"
        case .files: "folder"
        case .rules: "doc.badge.gearshape"
        case .skills: "hammer"
        }
    }
}

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
    case showHome
    case showProjects
    case showSessions
    case showGrid
    case showTerminal
    case showGit
    case showFiles
    case showRules
    case showSkills
    case restoreSessions
    case showSettings

    var id: Self { self }

    var title: String {
        switch self {
        case .newSession: "New session"
        case .showHome: "Go to Home"
        case .showProjects: "Go to Projects"
        case .showSessions: "Go to Sessions"
        case .showGrid: "Show session grid"
        case .showTerminal: "Open Terminal"
        case .showGit: "Review Git changes"
        case .showFiles: "Browse project files"
        case .showRules: "Edit agent rules"
        case .showSkills: "Browse agent skills"
        case .restoreSessions: "Restore stopped sessions"
        case .showSettings: "Open Settings"
        }
    }

    var subtitle: String {
        switch self {
        case .newSession: "Launch an agent in a checkout or worktree"
        case .showHome: "Open the goal-first launch dashboard"
        case .showProjects: "Browse local project workspaces"
        case .showSessions: "Return to active session focus"
        case .showGrid: "Tile every live terminal"
        case .showTerminal: "Focus the selected session's terminal"
        case .showGit: "Inspect staged, unstaged, and untracked changes"
        case .showFiles: "Open the selected worktree's file editor"
        case .showRules: "Open CLAUDE.md, AGENTS.md, and GEMINI.md"
        case .showSkills: "Open project skill definitions"
        case .restoreSessions: "Restart finished or crashed sessions"
        case .showSettings: "Configure agents, worktrees, and appearance"
        }
    }

    var systemImage: String {
        switch self {
        case .newSession: "plus"
        case .showHome: "house"
        case .showProjects: "folder"
        case .showSessions: "terminal"
        case .showGrid: "square.grid.2x2"
        case .showTerminal: "terminal"
        case .showGit: "plusminus"
        case .showFiles: "folder"
        case .showRules: "doc.badge.gearshape"
        case .showSkills: "hammer"
        case .restoreSessions: "arrow.clockwise"
        case .showSettings: "gearshape"
        }
    }
}

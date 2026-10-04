import SwiftUI
import SessionKit

/// The Workspace menu, split into sections that are each their own `View`.
///
/// Written inline as one `CommandMenu` builder, the menu's ~20 items formed a
/// single result type nested so deeply that resolving its metadata at launch
/// recursed past the main thread's 8 MB stack in Debug builds — an
/// intermittent `EXC_BAD_ACCESS` ("Thread stack size exceeded due to
/// excessive recursion") in `View.keyboardShortcut`, which also crashed unit
/// test hosts at random. Each struct below is an opaque boundary, keeping
/// every type shallow. Keep new items inside a section, not at the top level.
struct WorkspaceMenuCommands: Commands {
    let store: AppStore
    let navigator: WorkspaceNavigator

    var body: some Commands {
        CommandMenu("Workspace") {
            WorkspaceNavigationItems(navigator: navigator)
            Divider()
            WorkspaceLayoutItems(navigator: navigator)
            Divider()
            WorkspacePanelItems(store: store, navigator: navigator)
            Divider()
            WorkspaceSessionItems(store: store, navigator: navigator)
        }
    }
}

private struct WorkspaceNavigationItems: View {
    let navigator: WorkspaceNavigator

    var body: some View {
        Button("Back") { navigator.goBack() }
            .keyboardShortcut("[", modifiers: .command)
            .disabled(!navigator.canGoBack)
        Button("Forward") { navigator.goForward() }
            .keyboardShortcut("]", modifiers: .command)
            .disabled(!navigator.canGoForward)
        Divider()
        Button("Home") {
            navigator.restoreHomeSelection()
        }
        .keyboardShortcut("1", modifiers: .command)
        Button("All Sessions") {
            navigator.selection = .allSessions
            navigator.presentation = .focus
        }
        .keyboardShortcut("2", modifiers: .command)
        Divider()
        ForEach(FleetSmartList.allCases) { list in
            Button(list.title) {
                navigator.selection = .smartList(list)
            }
        }
    }
}

private struct WorkspaceLayoutItems: View {
    let navigator: WorkspaceNavigator

    var body: some View {
        Button("Focus Layout") { show(.focus) }
            .keyboardShortcut("1", modifiers: [.command, .control])
        Button("Grid Layout") { show(.grid) }
            .keyboardShortcut("2", modifiers: [.command, .control])
        Button("Board Layout") { show(.board) }
            .keyboardShortcut("3", modifiers: [.command, .control])
    }

    private func show(_ presentation: WorkspacePresentation) {
        navigator.selection = .allSessions
        navigator.presentation = presentation
    }
}

private struct WorkspacePanelItems: View {
    let store: AppStore
    let navigator: WorkspaceNavigator
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Button("Review\u{2026}") {
            if let session = store.selectedSession {
                openWindow(id: SessionReviewWindow.sceneID, value: session.id)
            }
        }
        .keyboardShortcut("r", modifiers: [.command, .shift])
        .disabled(store.selectedSession?.status != .readyForReview)
        Button("Changes") {
            navigator.openProjectPanel(.git, scopedTo: store.selectedSession)
        }
        .keyboardShortcut("g", modifiers: [.command, .shift])
        Button("Files") {
            navigator.openProjectPanel(.files, scopedTo: store.selectedSession)
        }
        .keyboardShortcut("f", modifiers: [.command, .shift])
        Button("Instructions") {
            navigator.openProjectPanel(.rules, scopedTo: store.selectedSession)
        }
        .keyboardShortcut("i", modifiers: [.command, .shift])
    }
}

private struct WorkspaceSessionItems: View {
    let store: AppStore
    let navigator: WorkspaceNavigator

    var body: some View {
        Button("Previous Session") { step(by: -1) }
            .keyboardShortcut("[", modifiers: [.command, .option])
        Button("Next Session") { step(by: 1) }
            .keyboardShortcut("]", modifiers: [.command, .option])
        Divider()
        Button("Restart Session") {
            if let session = store.selectedSession {
                store.restartSession(sessionID: session.id)
            }
        }
        .keyboardShortcut("r", modifiers: .command)
        Button("Delete Session…") {
            if let session = store.selectedSession {
                navigator.presentedSheet = .deleteSession(session.id)
            }
        }
        .keyboardShortcut(.delete, modifiers: .command)
        Divider()
        Button("Command Palette…") {
            navigator.presentedSheet = .commandPalette
        }
        .keyboardShortcut("k", modifiers: .command)
    }

    /// Cycles through sessions by recency, wrapping at either end; with no
    /// session selected, lands on the most recent.
    private func step(by offset: Int) {
        let sorted = store.sessions.sorted(by: { $0.lastActiveAt > $1.lastActiveAt })
        guard !sorted.isEmpty else { return }
        let target: Session
        if let currentID = store.selectedSessionID,
           let index = sorted.firstIndex(where: { $0.id == currentID }) {
            target = sorted[(index + offset + sorted.count) % sorted.count]
        } else {
            target = sorted[0]
        }
        navigator.selection = .session(target.id)
        store.selectedSessionID = target.id
    }
}

import SwiftUI
import SessionKit
import DesignSystem

struct WorkspaceToolbar: ToolbarContent {
    @Environment(\.openSettings) private var openSettings
    @Bindable var navigator: WorkspaceNavigator
    @Bindable var store: AppStore
    @Bindable var settingsViewModel: SettingsViewModel
    let onCommandPalette: () -> Void

    /// True for the scopes that render a multi-session workspace, which are
    /// the only ones where the grid's own options mean anything.
    private var isFleetScope: Bool {
        switch navigator.selection {
        case .allSessions: true
        case .overview, .session, .project: false
        }
    }

    /// The picker also shows while a single session is focused — that is the
    /// only way back to the fleet without going through the sidebar.
    /// Hidden for project scope: the five-tab strip already fills the
    /// principal area, and two competing tab bars confuse the hierarchy.
    private var showsPresentationPicker: Bool {
        switch navigator.selection {
        case .allSessions, .session: true
        case .overview, .project: false
        }
    }

    private var gridDimensions: GridDimensions {
        GridDimensions(
            columns: settingsViewModel.settings.workspace.gridColumnCount,
            rows: settingsViewModel.settings.workspace.gridRowCount
        )
    }

    private var presentation: Binding<WorkspacePresentation> {
        Binding(
            get: { navigator.presentation },
            set: { newValue in
                navigator.presentation = newValue
                // Picking a fleet presentation from a focused session has to
                // leave that session, or the choice would change nothing on
                // screen: `.session` scope renders one terminal regardless.
                if case .session = navigator.selection {
                    navigator.selection = .allSessions
                }
            }
        )
    }

    var body: some ToolbarContent {
        ToolbarItemGroup(placement: .principal) {
            // Presentation picker - only show when in fleet scope
            if showsPresentationPicker {
                Picker("Presentation", selection: presentation) {
                    ForEach([WorkspacePresentation.grid, .board]) { mode in
                        Text(mode.title).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 116)
                .help("Switch presentation")
                .accessibilityIdentifier("Toolbar.PresentationPicker")
            }
        }

        if case .session(let sessionID) = navigator.selection,
           let session = store.sessions.first(where: { $0.id == sessionID }) {
            ToolbarItemGroup(placement: .primaryAction) {
                Button {
                    navigator.openProjectPanel(.git, scopedTo: session)
                } label: {
                    Image(systemName: "arrow.triangle.branch")
                }
                .help("Review this session's changes")
                .accessibilityIdentifier("Toolbar.OpenProjectGit")

                Button {
                    navigator.openProjectPanel(.files, scopedTo: session)
                } label: {
                    Image(systemName: "folder")
                }
                .help("Browse project files")
                .accessibilityIdentifier("Toolbar.OpenProjectFiles")
            }

            ToolbarSpacer(.fixed, placement: .primaryAction)
        }

        // Its own glass container next to the other icon-button groups,
        // rather than living beside the presentation picker — an unrelated
        // control shouldn't share a background with it.
        if isFleetScope, navigator.presentation == .grid {
            ToolbarItemGroup(placement: .primaryAction) {
                GridDimensionsPicker(settingsViewModel: settingsViewModel)
                GridAddAllButton(store: store, settingsViewModel: settingsViewModel, dimensions: gridDimensions)
                GridDimControl(settingsViewModel: settingsViewModel)
                GridEmptyButton(store: store, settingsViewModel: settingsViewModel)
            }

            ToolbarSpacer(.fixed, placement: .primaryAction)
        }

        ToolbarItemGroup(placement: .primaryAction) {
            Button(action: onCommandPalette) {
                Image(systemName: "command")
            }
            .help("Command palette")
            .accessibilityIdentifier("Toolbar.CommandPalette")

            Button(action: { openSettings() }) {
                Image(systemName: "gearshape")
            }
            .help("Settings (⌘,)")
            .accessibilityIdentifier("Toolbar.Settings")
        }
    }
}

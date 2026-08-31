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
    private var isFleetScope: Bool { navigator.selection.isCollection }

    /// The picker also shows while a single session is focused — that is the
    /// only way back to the fleet without going through the navigator.
    /// Hidden for project scope: the five-tab strip already fills the
    /// principal area, and two competing tab bars confuse the hierarchy.
    private var showsPresentationPicker: Bool {
        switch navigator.selection {
        case .allSessions, .smartList, .session: true
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
        // Leading Flotilla brand mark. `.navigation` pins it to the true
        // leading edge so it never reflows when principal/trailing items
        // appear, and `sharedBackgroundVisibility(.hidden)` drops it out of
        // the toolbar's shared Liquid Glass grouping so it renders as a bare
        // wordmark with no capsule — see
        // https://developer.apple.com/documentation/swiftui/customizabletoolbarcontent/sharedbackgroundvisibility(_:)
        ToolbarItem(placement: .navigation) {
            HStack(spacing: 10) {
                Image(systemName: "sailboat.fill")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(FlotillaColors.accent)
                Text("Flotilla")
                    .font(.system(size: 17, weight: .bold, design: .rounded))
                    .foregroundStyle(FlotillaColors.textPrimary)
            }
            .accessibilityIdentifier("TopBar.Logo")
        }
        .sharedBackgroundVisibility(.hidden)

        // Fixed gap that also breaks the shared-glass grouping, so the wordmark
        // and the history controls sit in separate containers.
        ToolbarSpacer(.fixed, placement: .navigation)

        // Back / forward. The scope picker that used to sit here is gone with
        // the facet split — every destination is in the navigator now, so a
        // control for switching between two halves of the app has nothing left
        // to switch. History is what the space is actually worth: there was
        // previously no way to return to where you had been.
        ToolbarItemGroup(placement: .navigation) {
            Button {
                navigator.goBack()
            } label: {
                Image(systemName: "chevron.left")
            }
            .disabled(!navigator.canGoBack)
            .help("Back (⌘[)")
            .accessibilityIdentifier("Toolbar.Back")

            Button {
                navigator.goForward()
            } label: {
                Image(systemName: "chevron.right")
            }
            .disabled(!navigator.canGoForward)
            .help("Forward (⌘])")
            .accessibilityIdentifier("Toolbar.Forward")
        }

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
                .accessibilityIdentifier(AXID.toolbarPresentationPicker.rawValue)
            }
        }

        ToolbarSpacer()

        if case .session(let sessionID) = navigator.selection,
           let session = store.sessions.first(where: { $0.id == sessionID }) {
            // Both panels are project-owned containers that a session's data
            // gets injected into, so a session with no `projectID` — which is
            // an ordinary case, since the "Unassigned" group ships — has
            // nowhere for them to open. They used to render enabled, accept
            // the click and silently do nothing. Saying why beats pretending.
            let hasProject = session.projectID != nil

            ToolbarItemGroup(placement: .primaryAction) {
                Button {
                    navigator.openProjectPanel(.git, scopedTo: session)
                } label: {
                    Image(systemName: "arrow.triangle.branch")
                }
                .disabled(!hasProject)
                .help(hasProject
                      ? "Review this session's changes"
                      : "This session is not assigned to a project, so there is no repository workspace to open.")
                .accessibilityIdentifier(AXID.toolbarOpenProjectGit.rawValue)

                Button {
                    navigator.openProjectPanel(.files, scopedTo: session)
                } label: {
                    Image(systemName: "folder")
                }
                .disabled(!hasProject)
                .help(hasProject
                      ? "Browse project files"
                      : "This session is not assigned to a project, so there is no file tree to browse.")
                .accessibilityIdentifier(AXID.toolbarOpenProjectFiles.rawValue)
            }

            ToolbarSpacer(.fixed, placement: .primaryAction)
        }

        // Grid controls when grid is active
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
            .help("Command palette (⌘K)")
            .accessibilityIdentifier(AXID.toolbarCommandPalette.rawValue)

            Button(action: { openSettings() }) {
                Image(systemName: "gearshape")
            }
            .help("Settings (⌘,)")
            .accessibilityIdentifier("Toolbar.Settings")
        }
    }
}

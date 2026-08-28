import SwiftUI
import SessionKit
import DesignSystem

struct WorkspaceToolbar: ToolbarContent {
    @Environment(\.openSettings) private var openSettings
    @Bindable var navigator: WorkspaceNavigator
    @Bindable var store: AppStore
    @Bindable var settingsViewModel: SettingsViewModel
    let onCommandPalette: () -> Void

    private var facet: SidebarFacet {
        SidebarFacet(navigator.selection)
    }

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

    private var facetBinding: Binding<SidebarFacet> {
        Binding(
            get: { facet },
            set: { newFacet in
                switch newFacet {
                case .overview:
                    navigator.restoreOverviewSelection()
                case .sessions:
                    navigator.selection = .allSessions
                }
            }
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
        // and the scope picker sit in separate containers.
        ToolbarSpacer(.fixed, placement: .navigation)

        // Scope Picker: Projects / Sessions (segmented, matched to the
        // Grid / Board presentation picker). Also `.navigation` so the leading
        // cluster stays put across every scope.
        ToolbarItem(placement: .navigation) {
            Picker("Scope", selection: facetBinding) {
                ForEach(SidebarFacet.allCases) { facet in
                    Text(facet.title).tag(facet)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 144)
            .help("Switch workspace scope")
            .accessibilityIdentifier(AXID.toolbarScopePicker.rawValue)
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
            ToolbarItemGroup(placement: .primaryAction) {
                Button {
                    navigator.openProjectPanel(.git, scopedTo: session)
                } label: {
                    Image(systemName: "arrow.triangle.branch")
                }
                .help("Review this session's changes")
                .accessibilityIdentifier(AXID.toolbarOpenProjectGit.rawValue)

                Button {
                    navigator.openProjectPanel(.files, scopedTo: session)
                } label: {
                    Image(systemName: "folder")
                }
                .help("Browse project files")
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

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
        ToolbarItem(placement: .primaryAction) {
            Button(action: onCommandPalette) {
                Image(systemName: "command")
            }
            .help("Command palette")
            .accessibilityIdentifier("Toolbar.CommandPalette")
        }

        ToolbarItemGroup(placement: .principal) {
            if case .session(let sessionID) = navigator.selection,
               let session = store.sessions.first(where: { $0.id == sessionID }) {
                SessionToolbarView(
                    session: session,
                    project: store.project(for: session),
                    gitService: store.gitService,
                    selectedLens: $navigator.sessionLens
                )
                .id(session.id)
            } else {
                // Presentation picker - only show when in fleet scope
                if showsPresentationPicker {
                    Picker("Presentation", selection: presentation) {
                        ForEach([WorkspacePresentation.grid, .board, .list]) { mode in
                            Text(mode.title).tag(mode)
                        }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .frame(width: 170)
                    .help("Switch presentation")
                    .accessibilityIdentifier("Toolbar.PresentationPicker")
                }

                if isFleetScope, navigator.presentation == .grid {
                    GridLayoutControls(settingsViewModel: settingsViewModel)
                }
            }
        }

        ToolbarItem(placement: .primaryAction) {
            Button(action: { openSettings() }) {
                Image(systemName: "gearshape")
            }
            .help("Settings (⌘,)")
            .accessibilityIdentifier("Toolbar.Settings")
        }
    }
}

/// Tile size, as a two-button stepper.
///
/// One click per step, nothing to open first. Command-plus and Command-minus
/// are attached here so the shortcuts live with the buttons they mirror;
/// pinch and Command-scroll are handled on the grid itself.
///
/// Bound straight to the persisted setting — the previous grid kept a second
/// copy of the tile width in a `@Binding`, and the two copies disagreeing is
/// why the old density control appeared to do nothing.
private struct GridLayoutControls: View {
    @Bindable var settingsViewModel: SettingsViewModel

    private var zoom: GridZoom {
        GridZoom(setting: settingsViewModel.settings.workspace.gridMinimumTileWidth)
    }

    private func apply(_ newZoom: GridZoom) {
        settingsViewModel.settings.workspace.gridMinimumTileWidth = newZoom.setting
    }

    var body: some View {
        HStack(spacing: 0) {
            Button {
                apply(zoom.zoomedOut())
            } label: {
                Image(systemName: "minus")
                    .frame(width: 26, height: 22)
                    .contentShape(Rectangle())
            }
            .disabled(!zoom.canZoomOut)
            .help("Smaller tiles (⌘−)")
            .keyboardShortcut("-", modifiers: .command)
            .accessibilityIdentifier("Toolbar.GridZoomOut")

            Image(systemName: "square.grid.2x2")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .frame(width: 22)
                .accessibilityHidden(true)

            Button {
                apply(zoom.zoomedIn())
            } label: {
                Image(systemName: "plus")
                    .frame(width: 26, height: 22)
                    .contentShape(Rectangle())
            }
            .disabled(!zoom.canZoomIn)
            .help("Larger tiles (⌘+)")
            .keyboardShortcut("+", modifiers: .command)
            .accessibilityIdentifier("Toolbar.GridZoomIn")

            // `⌘+` needs Shift on most layouts, so bind the unshifted `⌘=`
            // that users actually press. A button can carry only one shortcut,
            // hence the zero-sized twin.
            Button { apply(zoom.zoomedIn()) } label: { EmptyView() }
                .keyboardShortcut("=", modifiers: .command)
                .disabled(!zoom.canZoomIn)
                .frame(width: 0, height: 0)
                .opacity(0)
                .accessibilityHidden(true)
        }
        .buttonStyle(.borderless)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Tile size")
    }
}
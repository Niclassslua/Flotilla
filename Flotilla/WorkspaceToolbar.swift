import SwiftUI
import SessionKit
import DesignSystem

struct WorkspaceToolbar: ToolbarContent {
    @Environment(\.openSettings) private var openSettings
    @Bindable var navigator: WorkspaceNavigator
    @Bindable var store: AppStore
    @Bindable var settingsViewModel: SettingsViewModel
    let onCommandPalette: () -> Void
    let onInspectorToggle: () -> Void

    /// True for the scopes that render a multi-session workspace, which are
    /// the only ones where the grid's own options mean anything.
    private var isFleetScope: Bool {
        switch navigator.selection {
        case .allSessions, .project: true
        case .overview, .allProjects, .session: false
        }
    }

    /// The picker also shows while a single session is focused — that is the
    /// only way back to the fleet without going through the sidebar.
    private var showsPresentationPicker: Bool {
        switch navigator.selection {
        case .allSessions, .project, .session: true
        case .overview, .allProjects: false
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
        ToolbarItemGroup(placement: .primaryAction) {
            // New Session lives on the sidebar rail now (see FleetSidebar) —
            // a second "+" up here was redundant. Cmd+N still works via the
            // app's Workspace menu command.

            // Command Palette
            Button(action: onCommandPalette) {
                Image(systemName: "command")
            }
            .help("Command palette")
            .accessibilityIdentifier("Toolbar.CommandPalette")
            .keyboardShortcut("k", modifiers: .command)

            // Inspector toggle
            Button(action: onInspectorToggle) {
                Image(systemName: "sidebar.right")
            }
            .help("Toggle inspector")
            .accessibilityIdentifier("Toolbar.InspectorToggle")
            .keyboardShortcut("g", modifiers: [.command, .shift])
        }

        ToolbarItemGroup(placement: .principal) {
            // Presentation picker - only show when in fleet scope
            if showsPresentationPicker {
                Picker("Presentation", selection: presentation) {
                    // Text, not Label: a segmented picker renders icon-only,
                    // and Grid's `square.grid.2x2` against Board's
                    // `square.grid.2x2.fill` is not a distinction anyone can
                    // read at 16pt.
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

        ToolbarItemGroup(placement: .primaryAction) {
            // Overflow menu
            Menu {
                if let session = store.selectedSession {
                    Button("Restore") {
                        store.restartSession(sessionID: session.id)
                    }
                    .keyboardShortcut("r", modifiers: .command)
                    .accessibilityIdentifier("Restore Session")

                    Button("Reveal in Finder") {
                        let path = session.worktree?.worktreePath ?? session.workingDirectory
                        NSWorkspace.shared.activateFileViewerSelecting([path])
                    }

                    Button("Copy Working Directory") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString((session.worktree?.worktreePath ?? session.workingDirectory).path, forType: .string)
                    }

                    Button("Copy Branch") {
                        if let branch = session.worktree?.branchName {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(branch, forType: .string)
                        }
                    }

                    Divider()

                    Button("Delete Session…", role: .destructive) {
                        navigator.presentedSheet = .deleteSession(session.id)
                    }
                    .keyboardShortcut(.delete, modifiers: .command)
                }

                Divider()

                Button("Keyboard Shortcuts") {
                    navigator.presentedSheet = .shortcuts
                }

                Button("Settings…") { openSettings() }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .menuStyle(.borderlessButton)
            .help("More actions")
            .accessibilityIdentifier("Toolbar.Overflow")
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
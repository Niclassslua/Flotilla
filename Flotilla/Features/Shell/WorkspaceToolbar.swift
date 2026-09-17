import SwiftUI
import SessionKit
import DesignSystem

/// The global bar: the one bar that is present in every scope.
///
/// It carries only what is true everywhere — who the app is, where you have
/// been, where you can go, and the two launchers. Everything scope-specific
/// moved to a bar that shares that scope's lifetime: the grid's layout
/// controls and the group chips to `SessionGroupBar`, a session's Git/Files
/// actions to `SessionBar`. Before that split this row gained and lost four
/// controls as the selection changed, so the buttons that *were* always there
/// slid sideways under the pointer.
struct WorkspaceToolbar: ToolbarContent {
    @Environment(\.openSettings) private var openSettings
    @Bindable var navigator: WorkspaceNavigator
    @Bindable var store: AppStore
    @Bindable var settingsViewModel: SettingsViewModel
    let onCommandPalette: () -> Void

    /// A presentation button is lit when its presentation is the one actually
    /// rendering the fleet — which requires a collection destination, not
    /// merely a remembered `presentation` value.
    private func isPresenting(_ mode: WorkspacePresentation) -> Bool {
        navigator.selection.isCollection && navigator.presentation == mode
    }

    /// Both buttons are destinations, not a mode switch: pressing one from
    /// Home, a project, or a focused session lands in Sessions with that
    /// presentation live. Same move as `WorkspaceCommand.showGrid`/`.showBoard`.
    private func show(_ mode: WorkspacePresentation) {
        navigator.selection = .allSessions
        navigator.presentation = mode
    }

    /// Pressing a lit presentation button again turns it off, dropping back to
    /// the single-session Focus view. Without this, entering Grid or Board from
    /// the toolbar left no way back out from the same control.
    private func toggle(_ mode: WorkspacePresentation) {
        if isPresenting(mode) {
            navigator.presentation = .focus
        } else {
            show(mode)
        }
    }

    var body: some ToolbarContent {
        // Leading Flotilla brand mark. `.navigation` pins it to the true
        // leading edge so it never reflows when principal/trailing items
        // appear, and `sharedBackgroundVisibility(.hidden)` drops it out of
        // the toolbar's shared Liquid Glass grouping so it renders as a bare
        // wordmark with no capsule — see
        // https://developer.apple.com/documentation/swiftui/customizabletoolbarcontent/sharedbackgroundvisibility(_:)
        ToolbarItem(placement: .navigation) {
            FlotillaWordmark(pointSize: 17)
            .accessibilityIdentifier(AXID.topBarLogo.rawValue)
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
            .accessibilityIdentifier(AXID.toolbarBack.rawValue)

            Button {
                navigator.goForward()
            } label: {
                Image(systemName: "chevron.right")
            }
            .disabled(!navigator.canGoForward)
            .help("Forward (⌘])")
            .accessibilityIdentifier(AXID.toolbarForward.rawValue)
        }

        // Everything after this point sits at the trailing edge. No placement
        // does that on macOS — `.primaryAction` and `.automatic` both resolve
        // to the leading run of the toolbar, right after the navigation items,
        // which is why the global actions used to sit against the back/forward
        // pair. A flexible `ToolbarSpacer` is what separates a leading group
        // from a trailing one; it absorbs the slack between them. It only works
        // from a toolbar declared inside the split view — see `FlotillaShell`.
        ToolbarSpacer(.flexible)

        // Grid and Board, always present and always enabled. The segmented
        // picker they replace was hidden in exactly the scopes you would want
        // it from — Home and a project workspace — so reaching the grid from
        // there meant a detour through the navigator. Keeping all four global
        // actions in one group anchors them together.
        ToolbarItemGroup(placement: .automatic) {
            presentationButton(.grid, help: "Session grid", activeHelp: "Exit session grid", identifier: .toolbarShowGrid)
            presentationButton(.board, help: "Kanban board", activeHelp: "Exit Kanban board", identifier: .toolbarShowBoard)

            Button(action: onCommandPalette) {
                Image(systemName: "command")
            }
            .help("Command palette (⌘K)")
            .accessibilityIdentifier(AXID.toolbarCommandPalette.rawValue)

            Button(action: { openSettings() }) {
                Image(systemName: "gearshape")
            }
            .help("Settings (⌘,)")
            .accessibilityIdentifier(AXID.toolbarSettings.rawValue)
        }
    }

    private func presentationButton(
        _ mode: WorkspacePresentation,
        help: String,
        activeHelp: String,
        identifier: AXID
    ) -> some View {
        let isActive = isPresenting(mode)
        return Button {
            toggle(mode)
        } label: {
            Image(systemName: mode.systemImage)
                .font(.system(size: 15, weight: .medium))
        }
        .controlSize(.large)
        .foregroundStyle(isActive ? FlotillaColors.accent : FlotillaColors.textPrimary)
        .help(isActive ? activeHelp : help)
        .accessibilityAddTraits(isActive ? [.isSelected] : [])
        .accessibilityIdentifier(identifier.rawValue)
    }
}

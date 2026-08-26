import SwiftUI
import SessionKit
import DesignSystem

/// "Add all": fills the grid up to capacity with sessions not already
/// selected. Matches the icon-only style of the other toolbar buttons
/// (Git/Files, Command Palette) rather than the dimensions chip's custom
/// pill, since it carries no state of its own to label.
struct GridAddAllButton: View {
    @Bindable var store: AppStore
    @Bindable var settingsViewModel: SettingsViewModel
    let dimensions: GridDimensions

    private var isFull: Bool {
        GridSelection.memberIDs(
            selectedIDs: settingsViewModel.settings.workspace.gridSelectedSessionIDs,
            in: store.sessions
        ).count >= min(dimensions.capacity, store.sessions.count)
    }

    var body: some View {
        Button {
            settingsViewModel.addAllToGrid(from: store.sessions, capacity: dimensions.capacity)
        } label: {
            Image(systemName: "plus.square.on.square")
        }
        .disabled(store.sessions.isEmpty || isFull)
        .help("Add all sessions that fit (\(dimensions.label))")
        .accessibilityIdentifier("Grid.AddAllButton")
    }
}

/// "Empty grid": clears every session's grid membership.
struct GridEmptyButton: View {
    @Bindable var store: AppStore
    @Bindable var settingsViewModel: SettingsViewModel

    private var isEmpty: Bool {
        GridSelection.memberIDs(
            selectedIDs: settingsViewModel.settings.workspace.gridSelectedSessionIDs,
            in: store.sessions
        ).isEmpty
    }

    var body: some View {
        Button {
            settingsViewModel.emptyGrid()
        } label: {
            Image(systemName: "eraser")
        }
        .disabled(isEmpty)
        .help("Empty grid")
        .accessibilityIdentifier("Grid.EmptyButton")
    }
}

/// "Dim unfocused sessions": a chip that opens a popover with the toggle and
/// its intensity slider, the same interaction shape as the dimensions picker.
struct GridDimControl: View {
    @Bindable var settingsViewModel: SettingsViewModel

    @State private var isPresented = false

    private var isEnabled: Bool { settingsViewModel.settings.workspace.gridDimEnabled }

    var body: some View {
        Button {
            isPresented.toggle()
        } label: {
            Image(systemName: isEnabled ? "eye.fill" : "eye")
        }
        .foregroundStyle(isEnabled ? FlotillaColors.accent : FlotillaColors.textPrimary)
        .help("Dim unfocused sessions")
        .accessibilityIdentifier("Grid.DimButton")
        .popover(isPresented: $isPresented, arrowEdge: .bottom) {
            dimPopoverContent
        }
    }

    private var dimPopoverContent: some View {
        VStack(alignment: .leading, spacing: 10) {
            Toggle("Dim unfocused sessions", isOn: Binding(
                get: { settingsViewModel.settings.workspace.gridDimEnabled },
                set: { settingsViewModel.settings.workspace.gridDimEnabled = $0 }
            ))
            .toggleStyle(.switch)
            .controlSize(.small)

            HStack(spacing: 8) {
                Text("0%")
                    .font(.caption2)
                    .foregroundStyle(FlotillaColors.textTertiary)
                Slider(
                    value: Binding(
                        get: { settingsViewModel.settings.workspace.gridDimIntensity },
                        set: { settingsViewModel.settings.workspace.gridDimIntensity = $0 }
                    ),
                    in: 0...0.8
                )
                Text("80%")
                    .font(.caption2)
                    .foregroundStyle(FlotillaColors.textTertiary)
            }
            .disabled(!isEnabled)
            .opacity(isEnabled ? 1 : 0.5)
        }
        .padding(12)
        .frame(width: 220)
    }
}

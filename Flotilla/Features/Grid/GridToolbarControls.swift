import SwiftUI
import SessionKit
import DesignSystem

/// "Add all": fills the grid up to capacity with sessions from the active
/// group that are not already selected. Icon-only, matching the other bar
/// buttons rather than the dimensions chip's pill, since it carries no state
/// of its own to label.
struct GridAddAllButton: View {
    @Bindable var store: AppStore
    @Bindable var settingsViewModel: SettingsViewModel
    let dimensions: GridDimensions
    /// The group bar's current narrowing. Add all fills from what is on
    /// screen, not from the whole fleet — otherwise pressing it inside a
    /// project would silently fill the grid with other projects' sessions
    /// that the group is filtering straight back out.
    var scope: SessionScope = .everything

    private var candidates: [Session] { scope.apply(to: store.sessions) }

    private var memberIDs: Set<UUID> {
        GridSelection.memberIDs(
            selectedIDs: settingsViewModel.settings.workspace.gridSelectedSessionIDs,
            in: store.sessions
        )
    }

    /// Nothing left to add: either the grid is at capacity, or every session
    /// in the active group is already in it.
    private var isFull: Bool {
        let members = memberIDs
        return members.count >= dimensions.capacity
            || candidates.allSatisfy { members.contains($0.id) }
    }

    var body: some View {
        Button {
            settingsViewModel.addAllToGrid(
                candidates: candidates,
                allSessions: store.sessions,
                capacity: dimensions.capacity
            )
        } label: {
            Image(systemName: "plus.square.on.square")
        }
        .disabled(candidates.isEmpty || isFull)
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

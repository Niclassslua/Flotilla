import SwiftUI
import SessionKit
import DesignSystem

// MARK: - Shared chrome

/// Shared chrome for the four controls at the trailing end of `SessionGroupBar`.
///
/// They used to be bare `.borderless` buttons 4pt apart, which is what made
/// the cluster look crowded and unevenly spaced: `.borderless` paints nothing
/// at all on macOS, so what set each control's width was the intrinsic width
/// of its glyph — `plus.square.on.square` is half again as wide as `eraser` —
/// and with only 4pt between them the gaps read as random rather than equal.
/// A fixed-height chip with its own padding normalises the widths, so equal
/// spacing finally looks equal, and gives each control a 28pt target and a
/// hover state that a bare glyph never had.
///
/// The `isOn` treatment is deliberately the group chips' own: same accent
/// fill at `FlotillaStateOpacity.selected`, same half-strength accent border.
/// Those chips sit at the other end of this very bar, so "this control is
/// currently on" should not be spelled two different ways within 40 points.
struct GridBarControl<Label: View>: View {
    var isOn: Bool = false
    let help: String
    let action: () -> Void
    @ViewBuilder var label: () -> Label

    /// Read from the environment so a caller's `.disabled(...)` — Add all at
    /// capacity, Empty on an already-empty grid — reaches the chip's own
    /// colours, not just the label's.
    @Environment(\.isEnabled) private var isEnabled
    @State private var isHovering = false

    private var foreground: Color {
        guard isEnabled else { return FlotillaColors.textTertiary }
        if isOn { return FlotillaColors.accent }
        return isHovering ? FlotillaColors.textPrimary : FlotillaColors.textSecondary
    }

    private var fill: Color {
        if isOn { return FlotillaColors.accent.opacity(FlotillaStateOpacity.selected) }
        if isHovering && isEnabled { return FlotillaColors.textPrimary.opacity(FlotillaStateOpacity.hover) }
        return .clear
    }

    var body: some View {
        Button(action: action) {
            label()
                .foregroundStyle(foreground)
                .padding(.horizontal, 7)
                .frame(minWidth: 28, minHeight: 26)
                .background {
                    RoundedRectangle(cornerRadius: FlotillaRadius.control, style: .continuous)
                        .fill(fill)
                        .overlay {
                            RoundedRectangle(cornerRadius: FlotillaRadius.control, style: .continuous)
                                .strokeBorder(
                                    isOn ? FlotillaColors.accent.opacity(0.5) : .clear,
                                    lineWidth: 1
                                )
                        }
                }
                .contentShape(RoundedRectangle(cornerRadius: FlotillaRadius.control, style: .continuous))
        }
        .buttonStyle(.plain)
        .help(help)
        // Guarded on `isEnabled` so a disabled control never lights up, while
        // the pointer still gets the tooltip saying what it would have done.
        .onHover { isHovering = isEnabled && $0 }
        .withFlotillaMotion(.fast, value: isHovering)
        .withFlotillaMotion(.fast, value: isOn)
    }
}

/// The icon every chip in this bar draws at, so a wide glyph and a narrow one
/// still read as the same weight of control.
extension View {
    func gridBarIcon() -> some View {
        font(.system(size: 13, weight: .medium))
    }
}

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
        GridBarControl(help: "Add all sessions that fit (\(dimensions.label))") {
            settingsViewModel.addAllToGrid(
                candidates: candidates,
                allSessions: store.sessions,
                capacity: dimensions.capacity
            )
        } label: {
            Image(systemName: "plus.square.on.square").gridBarIcon()
        }
        .disabled(candidates.isEmpty || isFull)
        .accessibilityLabel("Add all sessions that fit")
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
        GridBarControl(help: "Empty grid") {
            settingsViewModel.emptyGrid()
        } label: {
            // Paired with Add all's `plus.square.on.square` rather than the
            // unrelated `eraser` it used to draw: the two sit side by side and
            // do opposite things to the same list, which the matched glyphs
            // say and two unrelated ones did not.
            Image(systemName: "minus.square.on.square").gridBarIcon()
        }
        .disabled(isEmpty)
        .accessibilityLabel("Empty grid")
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
        // "On" is carried by the chip's accent fill, not by tinting a bare
        // glyph accent-on-nothing: a lone coloured icon among three grey ones
        // reads as an odd icon rather than as a control that is switched on.
        GridBarControl(isOn: isEnabled, help: "Dim unfocused sessions") {
            isPresented.toggle()
        } label: {
            Image(systemName: isEnabled ? "eye.fill" : "eye").gridBarIcon()
        }
        .accessibilityLabel("Dim unfocused sessions")
        .accessibilityValue(isEnabled ? "On" : "Off")
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

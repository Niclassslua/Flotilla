import SwiftUI
import SessionKit
import DesignSystem

/// The second bar: which slice of the fleet the Sessions destination is
/// showing, and — in Grid only — the grid's own layout controls.
///
/// An in-window bar rather than more window-toolbar content, deliberately.
/// The grid controls used to live in the toolbar with a comment in `GridView`
/// defending the choice on vertical-space grounds; what that cost instead was
/// a toolbar row that gained and lost four controls as the selection changed,
/// reflowing under the pointer. Forty points buys a bar whose contents
/// are stable for as long as you are in Sessions.
///
/// Shown for both Grid and Board, so the group survives switching between
/// them — scope changes *what* is on screen, presentation changes *how*, and
/// the two must not be entangled.
struct SessionGroupBar: View {
    @Bindable var store: AppStore
    @Bindable var navigator: WorkspaceNavigator
    @Bindable var settingsViewModel: SettingsViewModel
    /// Grid-only: the layout controls mean nothing on a Kanban board.
    var showsGridControls: Bool

    private var dimensions: GridDimensions {
        GridDimensions(
            columns: settingsViewModel.settings.workspace.gridColumnCount,
            rows: settingsViewModel.settings.workspace.gridRowCount
        )
    }

    var body: some View {
        HStack(spacing: FlotillaSpacing.medium) {
            groupChips
            Spacer(minLength: FlotillaSpacing.small)
            if showsGridControls {
                gridControls
            }
        }
        .padding(.horizontal, FlotillaSpacing.medium)
        .frame(height: 40)
        .background(FlotillaColors.surface)
        .accessibilityIdentifier(AXID.sessionsGroupBar.rawValue)
    }

    // MARK: - Groups

    /// One chip per group that has something in it. A project with no
    /// sessions is not offered — the bar is a way to narrow a fleet, and a
    /// chip that can only ever produce an empty grid is noise.
    private var groups: [SessionGroupChip] {
        let filtered = store.sidebarFilter(matching: "")
        var chips: [SessionGroupChip] = [
            SessionGroupChip(group: .all, title: "All", count: store.sessions.count, tint: FlotillaColors.accent)
        ]
        for project in filtered.projects {
            let count = filtered.sessionsByProject[project.id]?.count ?? 0
            guard count > 0 else { continue }
            chips.append(
                SessionGroupChip(
                    group: .project(project.id),
                    title: project.name,
                    count: count,
                    tint: ProjectMark.tint(for: project)
                )
            )
        }
        if !filtered.generalSessions.isEmpty {
            chips.append(
                SessionGroupChip(
                    group: .general,
                    title: "General",
                    count: filtered.generalSessions.count,
                    systemImage: "tray",
                    tint: FlotillaColors.textSecondary
                )
            )
        }
        return chips
    }

    private var groupChips: some View {
        ScrollView(.horizontal) {
            HStack(spacing: FlotillaSpacing.xSmall) {
                ForEach(groups) { chip in
                    chipButton(chip)
                }
            }
            .padding(.vertical, 2)
        }
        .scrollIndicators(.never)
    }

    private func chipButton(_ chip: SessionGroupChip) -> some View {
        let isActive = navigator.sessionGroup == chip.group
        return Button {
            withAnimation(FlotillaMotion.fast.curve) {
                navigator.sessionGroup = chip.group
            }
        } label: {
            HStack(spacing: 6) {
                if chip.group != .all {
                    ProjectMark(title: chip.title, tint: chip.tint, systemImage: chip.systemImage, size: 15)
                }
                Text(chip.title)
                    .font(FlotillaTypography.callout.weight(isActive ? .semibold : .regular))
                    .lineLimit(1)
                Text("\(chip.count)")
                    .font(FlotillaTypography.caption.monospacedDigit())
                    .foregroundStyle(FlotillaColors.textTertiary)
            }
            .foregroundStyle(isActive ? FlotillaColors.textPrimary : FlotillaColors.textSecondary)
            .padding(.horizontal, FlotillaSpacing.medium)
            .padding(.vertical, 5)
            .background {
                Capsule(style: .continuous)
                    .fill(isActive ? FlotillaColors.accent.opacity(0.16) : .clear)
                    .overlay {
                        Capsule(style: .continuous)
                            .strokeBorder(isActive ? FlotillaColors.accent.opacity(0.5) : .clear, lineWidth: 1)
                    }
            }
            .contentShape(Capsule(style: .continuous))
        }
        .buttonStyle(.plain)
        .help("Show \(chip.title)")
        .accessibilityAddTraits(isActive ? [.isSelected] : [])
        .accessibilityIdentifier(AXID.sessionsGroup(chip.title))
    }

    // MARK: - Grid controls

    /// The same four views the window toolbar used to host. They read and write
    /// `settings.workspace` directly; their shared chrome is `GridBarControl`.
    ///
    /// Two pairs, not a run of four. Layout and dimming set how the grid draws
    /// what is in it and stay put once set; Add all and Empty are one-shot
    /// commands that change what is in it. Running all four together at one
    /// spacing invited reaching for Empty when you wanted the size picker —
    /// the divider is the cheapest way to say the two halves are different
    /// kinds of thing.
    ///
    /// Spacing 2 within a pair: the chips already carry their own padding, so
    /// a wider gap would break each pair back into loose single controls.
    private var gridControls: some View {
        HStack(spacing: FlotillaSpacing.small) {
            HStack(spacing: 2) {
                GridDimensionsPicker(settingsViewModel: settingsViewModel)
                GridDimControl(settingsViewModel: settingsViewModel)
            }

            Divider().frame(height: 16)

            HStack(spacing: 2) {
                GridAddAllButton(
                    store: store,
                    settingsViewModel: settingsViewModel,
                    dimensions: dimensions,
                    scope: navigator.sessionScope
                )
                GridEmptyButton(store: store, settingsViewModel: settingsViewModel)
            }
        }
    }
}

/// One offer in the group bar. A view model rather than a raw `SessionGroup`
/// because the chip needs the label, the count and the tint that go with it,
/// and deriving those inside the row body would re-scan the fleet per chip.
struct SessionGroupChip: Identifiable {
    let group: SessionGroup
    let title: String
    let count: Int
    var systemImage: String?
    let tint: Color

    var id: SessionGroup { group }
}

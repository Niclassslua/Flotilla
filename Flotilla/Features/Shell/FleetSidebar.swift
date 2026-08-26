import SwiftUI
import SessionKit
import DesignSystem

/// The fleet rail: a fixed-width icon column for Overview / Sessions /
/// Projects, pinned to the leading edge of the window.
///
/// It deliberately lives *outside* the `NavigationSplitView` (see
/// `FlotillaShell`). As a split-view column it could not hold its width:
/// AppKit keeps the divider wherever it was last left and ignores later
/// `navigationSplitViewColumnWidth` updates, so switching to Overview or
/// Projects — where the session list is hidden — left a 46pt rail floating
/// in the middle of a ~300pt column. Outside the split view the rail is
/// exactly as wide as it declares, and the split view's sidebar column is
/// simply collapsed for the facets that have no list to show.
struct SidebarRail: View {
    let facet: SidebarFacet
    let showLabels: Bool
    let onSelect: (SidebarFacet) -> Void
    let onCreateSession: () -> Void

    private var railWidth: CGFloat { showLabels ? 78 : 46 }

    var body: some View {
        VStack(spacing: showLabels ? 2 : 4) {
            ForEach(SidebarFacet.allCases) { item in
                railButton(item)
            }
            Spacer(minLength: 0)
            newSessionButton
        }
        .padding(.top, 10)
        .frame(width: railWidth)
        .frame(maxHeight: .infinity)
        .background(FlotillaColors.surface)
    }

    private func railButton(_ item: SidebarFacet) -> some View {
        let isActive = facet == item
        return Button {
            onSelect(item)
        } label: {
            railLabel(systemImage: item.systemImage, title: item.title, isActive: isActive)
        }
        .buttonStyle(.plain)
        .background(isActive ? FlotillaColors.accent.opacity(0.16) : .clear, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
        .foregroundStyle(isActive ? FlotillaColors.accent : FlotillaColors.textSecondary)
        .padding(.horizontal, showLabels ? 6 : 0)
        .help(item.title)
        .accessibilityIdentifier(item.axID)
    }

    private var newSessionButton: some View {
        Button(action: onCreateSession) {
            railLabel(systemImage: "plus", title: "New", isActive: false)
        }
        .buttonStyle(.plain)
        .background(FlotillaColors.accent.opacity(0.12), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
        .foregroundStyle(FlotillaColors.accent)
        .padding(.horizontal, showLabels ? 6 : 0)
        .padding(.bottom, 10)
        .help("New session")
        .accessibilityIdentifier("NewSessionButton")
    }

    @ViewBuilder
    private func railLabel(systemImage: String, title: String, isActive: Bool) -> some View {
        if showLabels {
            VStack(spacing: 3) {
                Image(systemName: systemImage)
                    .font(.system(size: 14, weight: isActive ? .semibold : .regular))
                Text(title)
                    .font(.caption2.weight(isActive ? .semibold : .regular))
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 7)
        } else {
            Image(systemName: systemImage)
                .font(.system(size: 15, weight: isActive ? .semibold : .regular))
                .frame(width: 30, height: 30)
        }
    }
}

// MARK: - Sessions list (the only facet with sidebar content)

/// The split view's sidebar column. Overview and Projects already show a
/// full picture in the detail column (HomeDashboardView / the "All Projects"
/// overview), so this column is collapsed for them rather than repeating it —
/// see `FlotillaShell.syncSidebarColumn`.
struct FleetSessionList: View {
    @Bindable var store: AppStore
    @Binding var selection: SidebarItem
    let searchText: String
    let onOpenSession: (UUID) -> Void
    /// Asks the host to put up the delete confirmation. The list does not
    /// delete anything itself — the sheet is owned by `FlotillaShell`, so
    /// every entry point into deletion shares one confirmation flow.
    let onRequestDelete: (UUID) -> Void
    /// While the grid is on screen, clicking a row assigns/unassigns that
    /// session to the grid instead of opening it — there's no reason to
    /// leave the grid just to build it. `nil` outside that context, which
    /// keeps every row's normal open-on-click behaviour.
    var gridSelection: GridSidebarSelection? = nil

    private var filtered: SidebarFilterResult { store.sidebarFilter(matching: searchText) }

    var body: some View {
        List(selection: $selection) {
            if filtered.projects.isEmpty && filtered.generalSessions.isEmpty {
                Text("No sessions yet").foregroundStyle(.secondary)
            }
            ForEach(filtered.projects) { project in
                let projectSessions = filtered.sessionsByProject[project.id] ?? []
                if !projectSessions.isEmpty {
                    Section(project.name) {
                        ForEach(projectSessions) { session in
                            SessionSidebarRow(session: session, selection: selection, store: store, onOpenSession: onOpenSession, onRequestDelete: onRequestDelete, gridSelection: gridSelection)
                        }
                    }
                }
            }
            if !filtered.generalSessions.isEmpty {
                Section("Unassigned") {
                    ForEach(filtered.generalSessions) { session in
                        SessionSidebarRow(session: session, selection: selection, store: store, onOpenSession: onOpenSession, onRequestDelete: onRequestDelete, gridSelection: gridSelection)
                    }
                }
            }
        }
        .listStyle(.sidebar)
        .scrollContentBackground(.hidden)
        .background(FlotillaColors.sidebar)
        .accessibilityIdentifier(AXID.sidebarList.rawValue)
    }
}

/// Bundles what a sidebar row needs to show and toggle grid membership,
/// passed as one optional value so most call sites (outside grid mode) don't
/// have to thread three separate parameters through just to pass `nil`.
struct GridSidebarSelection {
    let memberIDs: Set<UUID>
    let onToggle: (UUID) -> Void
}

// MARK: - Rail facet model

enum SidebarFacet: String, CaseIterable, Identifiable {
    case overview
    case sessions

    var id: Self { self }

    /// The rail highlights whichever facet the current scope belongs to, so
    /// opening a single session keeps Sessions lit, and overview/project keeps Overview lit.
    init(_ item: SidebarItem) {
        switch item {
        case .overview, .project: self = .overview
        case .allSessions, .session: self = .sessions
        }
    }

    /// Where the rail button navigates to.
    var rootItem: SidebarItem {
        switch self {
        case .overview: return .overview
        case .sessions: return .allSessions
        }
    }

    var title: String {
        switch self {
        case .overview: return "Overview"
        case .sessions: return "Sessions"
        }
    }

    var systemImage: String {
        switch self {
        case .overview: return "house"
        case .sessions: return "terminal"
        }
    }

    var axID: String {
        switch self {
        case .overview: return AXID.sidebarOverview.rawValue
        case .sessions: return AXID.sidebarAllSessions.rawValue
        }
    }
}

// MARK: - Shared search filtering

/// A project stays visible if its name matches `query` or at least one of
/// its sessions does; in the latter case only the matching sessions are
/// kept under it so results stay dense instead of showing whole projects.
struct SidebarFilterResult {
    let projects: [Project]
    let sessionsByProject: [UUID: [Session]]
    let generalSessions: [Session]
}

extension AppStore {
    func sidebarFilter(matching rawQuery: String) -> SidebarFilterResult {
        let query = rawQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else {
            let byProject = Dictionary(uniqueKeysWithValues: projects.map { ($0.id, sessions(for: $0)) })
            return SidebarFilterResult(projects: projects, sessionsByProject: byProject, generalSessions: generalSessions)
        }

        var visibleProjects: [Project] = []
        var byProject: [UUID: [Session]] = [:]
        for project in projects {
            let projectMatches = project.name.localizedCaseInsensitiveContains(query)
            let projectSessions = sessions(for: project)
            let matchingSessions = projectMatches
                ? projectSessions
                : projectSessions.filter { $0.title.localizedCaseInsensitiveContains(query) }
            if projectMatches || !matchingSessions.isEmpty {
                visibleProjects.append(project)
                byProject[project.id] = matchingSessions
            }
        }
        let matchingGeneral = generalSessions.filter { $0.title.localizedCaseInsensitiveContains(query) }
        return SidebarFilterResult(projects: visibleProjects, sessionsByProject: byProject, generalSessions: matchingGeneral)
    }
}

// MARK: - Shared session row

struct SessionSidebarRow: View {
    let session: Session
    let selection: SidebarItem
    let store: AppStore
    let onOpenSession: (UUID) -> Void
    let onRequestDelete: (UUID) -> Void
    var gridSelection: GridSidebarSelection? = nil

    @State private var isHovering = false

    private var isGridMember: Bool {
        gridSelection?.memberIDs.contains(session.id) ?? false
    }

    /// Green says "this session is in the grid"; red on hover previews that
    /// clicking removes it. Outside grid mode this stays nil and the card's
    /// own selection styling is untouched.
    private var gridTint: Color? {
        guard gridSelection != nil, isGridMember else { return nil }
        return isHovering ? FlotillaColors.danger : FlotillaColors.success
    }

    var body: some View {
        SessionCard(
            session: session,
            variant: .row,
            diffStatStore: store.diffStatStore,
            activityStore: nil,
            isSelected: selection == .session(session.id),
            // The row's own `Button` (see `SessionCard.rowView`) consumes
            // the click before it ever reaches `List`'s native row-selection
            // handling, so `FlotillaShell.sidebarSelectionBinding` never
            // sees it — this has to be the one place that actually toggles
            // membership.
            onTap: {
                if let gridSelection {
                    gridSelection.onToggle(session.id)
                } else {
                    onOpenSession(session.id)
                }
            },
            onDelete: { onRequestDelete(session.id) },
            onRestart: { store.restartSession(sessionID: session.id) },
            onRevealInFinder: { },
            onCopyPath: { },
            onCopyBranch: { },
            terminal: { EmptyView() }
        )
        // `List` reserves its own horizontal/vertical inset around every row
        // before this view ever sees the space; zeroing that out and
        // re-adding the same amount here (before the tint) lets the tint
        // reach the row's true full bounds instead of stopping at the inner
        // content SessionCard itself draws.
        .padding(.horizontal, 8)
        .padding(.vertical, 1)
        .background {
            if let gridTint {
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(gridTint.opacity(0.22))
            }
        }
        .animation(.easeOut(duration: 0.1), value: isHovering)
        .onHover { isHovering = $0 }
        .listRowInsets(EdgeInsets())
        .tag(SidebarItem.session(session.id))
        .accessibilityIdentifier(AXID.sessionRow(session.title))
        .accessibilityAddTraits(isGridMember ? .isSelected : [])
        .contextMenu {
            Button("Open Session") {
                onOpenSession(session.id)
            }
            if let gridSelection {
                Button(isGridMember ? "Remove from Grid" : "Add to Grid") {
                    gridSelection.onToggle(session.id)
                }
            }
            Divider()
            Button("Restart Session") {
                store.restartSession(sessionID: session.id)
            }
            .accessibilityIdentifier("Restart Session")
            Button("Reveal in Finder") {
                let path = session.worktree?.worktreePath ?? session.workingDirectory
                NSWorkspace.shared.activateFileViewerSelecting([path])
            }
            Button("Copy Path") {
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
                onRequestDelete(session.id)
            }
            .accessibilityIdentifier("SessionRow-\(session.title)-DeleteMenuItem")
        }
    }
}


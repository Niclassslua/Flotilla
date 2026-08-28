import SwiftUI
import SessionKit
import DesignSystem

/// The sessions sidebar: displays search at the top, a scrollable list of sessions
/// grouped by project, and a pinned "New Session" button at the bottom left.
/// Only shown when in the Sessions workspace.
struct SessionsSidebar: View {
    @Bindable var store: AppStore
    @Binding var selection: Set<SidebarItem>
    @Binding var searchText: String
    let onOpenSession: (UUID) -> Void
    let onRequestDelete: (UUID) -> Void
    let onCreateSession: () -> Void
    var gridSelection: GridSidebarSelection? = nil

    var body: some View {
        VStack(spacing: 0) {
            // Search field at top of sidebar
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 11))
                    .foregroundStyle(FlotillaColors.textSecondary)
                TextField("Search sessions…", text: $searchText)
                    .textFieldStyle(.plain)
                    .font(FlotillaTypography.caption)
                if !searchText.isEmpty {
                    Button(action: { searchText = "" }) {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 11))
                            .foregroundStyle(FlotillaColors.textSecondary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .background(FlotillaColors.surfaceElevated.opacity(0.5), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
            .padding(.horizontal, 10)
            .padding(.top, 10)
            .padding(.bottom, 6)

            // Scrollable List of Sessions
            FleetSessionList(
                store: store,
                selection: $selection,
                searchText: searchText,
                onOpenSession: onOpenSession,
                onRequestDelete: onRequestDelete,
                gridSelection: gridSelection
            )

            Divider()

            // Bottom Left "New Session" button
            HStack {
                Button(action: onCreateSession) {
                    HStack(spacing: 6) {
                        Image(systemName: "plus")
                            .font(.system(size: 11, weight: .bold))
                        Text("New Session")
                            .font(.system(size: 12, weight: .medium))
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(FlotillaColors.accent.opacity(0.12), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                    .foregroundStyle(FlotillaColors.accent)
                }
                .buttonStyle(.plain)
                .help("Create new session (⌘N)")
                .accessibilityIdentifier("NewSessionButton")

                Spacer()
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(FlotillaColors.surface)
        }
        .frame(minWidth: 240, idealWidth: 270, maxWidth: 340)
        .background(FlotillaColors.sidebar)
    }
}

// MARK: - Sessions list (the only facet with sidebar content)

/// The split view's sidebar column. Overview and Projects already show a
/// full picture in the detail column (HomeDashboardView / the "All Projects"
/// overview), so this column is collapsed for them rather than repeating it —
/// see `FlotillaShell.syncSidebarColumn`.
struct FleetSessionList: View {
    @Bindable var store: AppStore
    /// Native multi-select: a plain click, arrow key, or Shift/⌘-click
    /// range-selects through AppKit's own table-view handling, which is why
    /// rows no longer need a click-consuming `Button` (see
    /// `SessionSidebarRow`). `FlotillaShell.handleSidebarSelectionChange`
    /// folds a single-tag result back into `navigator.selection`; a
    /// multi-tag result is a batch selection that leaves the detail column
    /// alone.
    @Binding var selection: Set<SidebarItem>
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
                            SessionSidebarRow(session: session, isSelected: selection.contains(.session(session.id)), store: store, onOpenSession: onOpenSession, onRequestDelete: onRequestDelete, gridSelection: gridSelection)
                        }
                    }
                }
            }
            if !filtered.generalSessions.isEmpty {
                Section("Unassigned") {
                    ForEach(filtered.generalSessions) { session in
                        SessionSidebarRow(session: session, isSelected: selection.contains(.session(session.id)), store: store, onOpenSession: onOpenSession, onRequestDelete: onRequestDelete, gridSelection: gridSelection)
                    }
                }
            }
        }
        .listStyle(.sidebar)
        .scrollContentBackground(.hidden)
        .background(FlotillaColors.sidebar)
        .accessibilityIdentifier(AXID.sidebarList.rawValue)
        // Finder/Mail-standard: Delete/Backspace acts on whatever's
        // selected. Only wired for a single selected session for now — a
        // multi-row selection has no batch-delete confirmation sheet yet.
        .onDeleteCommand {
            guard selection.count == 1, case .session(let id)? = selection.first else { return }
            onRequestDelete(id)
        }
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
        case .overview: return "Projects"
        case .sessions: return "Sessions"
        }
    }

    var systemImage: String {
        switch self {
        case .overview: return "folder.fill"
        case .sessions: return "terminal.fill"
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
            return SidebarFilterResult(
                projects: projects,
                sessionsByProject: Dictionary(grouping: sessions.filter { $0.projectID != nil }) { $0.projectID! },
                generalSessions: sessions.filter { $0.projectID == nil }
            )
        }
        let matchingProjects = projects.filter { $0.name.localizedCaseInsensitiveContains(query) }
        let matchingProjectIDs = Set(matchingProjects.map(\.id))

        let matchingSessions = sessions.filter {
            $0.title.localizedCaseInsensitiveContains(query) ||
            $0.goal.localizedCaseInsensitiveContains(query) ||
            ($0.worktree?.branchName.localizedCaseInsensitiveContains(query) ?? false)
        }

        var sessionsByProject: [UUID: [Session]] = [:]
        for session in matchingSessions {
            if let pid = session.projectID {
                sessionsByProject[pid, default: []].append(session)
            }
        }
        for project in projects where matchingProjectIDs.contains(project.id) && sessionsByProject[project.id] == nil {
            sessionsByProject[project.id] = sessions(for: project)
        }

        let resultProjects = projects.filter { sessionsByProject.keys.contains($0.id) }
        let generalSessions = matchingSessions.filter { $0.projectID == nil }

        return SidebarFilterResult(
            projects: resultProjects,
            sessionsByProject: sessionsByProject,
            generalSessions: generalSessions
        )
    }
}

// MARK: - Session row component

struct SessionSidebarRow: View {
    let session: Session
    /// Whether this row is the item `navigator.selection` currently has
    /// open, from `FleetSessionList`'s `Set` membership check.
    let isSelected: Bool
    let store: AppStore
    let onOpenSession: (UUID) -> Void
    let onRequestDelete: (UUID) -> Void
    var gridSelection: GridSidebarSelection? = nil

    @State private var isHovering = false

    private var isGridMember: Bool {
        gridSelection?.memberIDs.contains(session.id) ?? false
    }

    /// Green says "this session is in the grid"; red on hover previews that
    /// clicking removes it. Outside grid mode this stays nil.
    private var gridTint: Color? {
        guard gridSelection != nil, isGridMember else { return nil }
        return isHovering ? FlotillaColors.danger : FlotillaColors.success
    }

    /// Exactly one state wins — layering translucent tints on top of each
    /// other (or on top of whatever AppKit's own `.sidebar`-style selection
    /// paints on the row underneath, which no `.background` can occlude
    /// since it's drawn by a separate `NSTableRowView` layer) is what
    /// produced a doubled-up look. Painting our own opaque backdrop first
    /// (below) hides that native layer entirely, so this is the only thing
    /// that's ever visible: grid membership beats "this is open", which
    /// beats needs-attention, which beats a plain hover, which beats idle.
    private var rowFill: Color {
        if let gridTint { return gridTint.opacity(0.22) }
        if isSelected { return FlotillaColors.surfaceElevated }
        if session.status == .waitingForInput { return FlotillaColors.statusWaitingForInput.opacity(0.14) }
        if isHovering { return FlotillaColors.surfaceElevated.opacity(0.6) }
        return .clear
    }

    var body: some View {
        SessionCard(
            session: session,
            variant: .row,
            diffStatStore: store.diffStatStore,
            activityStore: nil,
            onTap: { onOpenSession(session.id) },
            onDelete: { onRequestDelete(session.id) },
            onRestart: { store.restartSession(sessionID: session.id) },
            onRevealInFinder: { },
            onCopyPath: { },
            onCopyBranch: { },
            terminal: { EmptyView() }
        )
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background {
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(FlotillaColors.sidebar)
                .overlay {
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(rowFill)
                }
        }
        .animation(.easeOut(duration: 0.1), value: isHovering)
        .onHover { isHovering = $0 }
        .listRowInsets(EdgeInsets())
        .modifier(SwipeToDeleteSession(
            accessibilityID: "SessionRow-\(session.title)-SwipeDelete",
            onCommit: { Task { await store.deleteSession(sessionID: session.id, deleteWorktree: false) } },
            onConfirm: { onRequestDelete(session.id) }
        ))
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

private struct SwipeToDeleteSession: ViewModifier {
    private static let parkedThreshold: TimeInterval = 0.3

    let accessibilityID: String
    let onCommit: () -> Void
    let onConfirm: () -> Void

    @State private var openedAt: Date?

    func body(content: Content) -> some View {
        if #available(macOS 27, *) {
            content.swipeActions(edge: .trailing, allowsFullSwipe: true) {
                deleteButton {
                    let parked = openedAt.map { Date().timeIntervalSince($0) >= Self.parkedThreshold } ?? false
                    if parked { onConfirm() } else { onCommit() }
                }
            } onPresentationChanged: { visible in
                openedAt = visible ? Date() : nil
            }
        } else {
            content.swipeActions(edge: .trailing, allowsFullSwipe: true) {
                deleteButton(action: onConfirm)
            }
        }
    }

    private func deleteButton(action: @escaping () -> Void) -> some View {
        Button(role: .destructive, action: action) {
            Label("Delete", systemImage: "trash")
        }
        .accessibilityIdentifier(accessibilityID)
    }
}

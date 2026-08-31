import SwiftUI
import SessionKit
import DesignSystem

/// The navigator: search on top, then the fleet smart lists, then projects
/// with their sessions beneath them, then unassigned sessions, over a pinned
/// "New Session" button.
///
/// Present in every scope. It used to appear only in the Sessions facet, so
/// the window's left edge reflowed on every scope switch and half the app's
/// destinations were unreachable without first changing mode.
struct SessionsSidebar: View {
    @Bindable var store: AppStore
    @Binding var selection: Set<SidebarItem>
    @Binding var searchText: String
    let onOpenSession: (UUID) -> Void
    let onRequestDelete: (UUID) -> Void
    let onCreateSession: () -> Void
    /// Whether the grid is the current presentation, which is the only context
    /// where a row's grid-membership control means anything. It no longer
    /// changes what *clicking* a row does — see `SessionSidebarRow`.
    var gridMembership: GridMembership? = nil

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

            FleetSessionList(
                store: store,
                selection: $selection,
                searchText: searchText,
                onOpenSession: onOpenSession,
                onRequestDelete: onRequestDelete,
                gridMembership: gridMembership
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
        .background(FlotillaColors.sidebar)
    }
}

// MARK: - Navigator list

/// The split view's sidebar column, in every scope.
///
/// Three tiers in one list, so nothing is a mode: the fleet smart lists, then
/// each project as a selectable row with its sessions beneath it, then
/// unassigned sessions. Projects used to be plain `Section` headers — visible
/// but not selectable — which is why opening one meant leaving the sidebar
/// entirely and going through Home.
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
    /// Non-nil while the grid is the current presentation, enabling each row's
    /// explicit membership control. It no longer changes what clicking a row
    /// does: a click opens a session in every presentation.
    var gridMembership: GridMembership? = nil

    private var filtered: SidebarFilterResult { store.sidebarFilter(matching: searchText) }

    private var isSearching: Bool {
        !searchText.trimmingCharacters(in: .whitespaces).isEmpty
    }

    var body: some View {
        List(selection: $selection) {
            // Search narrows sessions and projects; the smart lists are
            // standing questions about the whole fleet, so they would be
            // answering the wrong question inside a filtered list.
            if !isSearching {
                Section {
                    NavigatorRow(item: .overview, title: "Home", systemImage: "house")
                        .accessibilityIdentifier(AXID.sidebarOverview.rawValue)

                    ForEach(FleetSmartList.allCases) { list in
                        NavigatorRow(
                            item: .smartList(list),
                            title: list.title,
                            systemImage: list.systemImage,
                            count: list.filter(store.sessions).count,
                            tint: list == .needsYou ? FlotillaColors.statusWaitingForInput : nil
                        )
                        .accessibilityIdentifier("Sidebar.SmartList-\(list.rawValue)")
                    }

                    NavigatorRow(
                        item: .allSessions,
                        title: "All Sessions",
                        systemImage: "square.stack.3d.up",
                        count: store.sessions.count
                    )
                    .accessibilityIdentifier(AXID.sidebarAllSessions.rawValue)
                }
            }

            if filtered.projects.isEmpty && filtered.generalSessions.isEmpty {
                Text(isSearching ? "No matches" : "No sessions yet")
                    .foregroundStyle(.secondary)
            }

            ForEach(filtered.projects) { project in
                let projectSessions = filtered.sessionsByProject[project.id] ?? []
                // No header: the project's own row is the header, and unlike a
                // `Section` header it can be selected to open the workspace.
                Section {
                    NavigatorRow(
                        item: .project(project.id),
                        title: project.name,
                        systemImage: "folder.fill",
                        count: projectSessions.count
                    )
                    .accessibilityIdentifier(AXID.sidebarProjectRow.rawValue + project.name)

                    ForEach(projectSessions) { session in
                        sessionRow(session)
                    }
                }
            }

            if !filtered.generalSessions.isEmpty {
                Section("Unassigned") {
                    ForEach(filtered.generalSessions) { session in
                        sessionRow(session)
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

    private func sessionRow(_ session: Session) -> some View {
        SessionSidebarRow(
            session: session,
            isSelected: selection.contains(.session(session.id)),
            store: store,
            onOpenSession: onOpenSession,
            onRequestDelete: onRequestDelete,
            gridMembership: gridMembership
        )
    }
}

// MARK: - Navigator row

/// A destination row: icon, label, optional count. Used for Home, the smart
/// lists, All Sessions, and projects — everything in the navigator that is not
/// a session.
private struct NavigatorRow: View {
    let item: SidebarItem
    let title: String
    var systemImage: String
    var count: Int? = nil
    /// Draws the count in a status colour when the row is about something
    /// actionable, so "Needs You 2" reads as urgent without a second control.
    var tint: Color? = nil

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: systemImage)
                .font(.system(size: 11))
                .frame(width: 16)
                .foregroundStyle(tint ?? FlotillaColors.textSecondary)

            Text(title)
                .font(FlotillaTypography.caption.weight(.medium))
                .lineLimit(1)
                .truncationMode(.middle)

            Spacer(minLength: 4)

            if let count, count > 0 {
                Text("\(count)")
                    .font(FlotillaTypography.caption3.monospacedDigit())
                    .foregroundStyle(tint ?? FlotillaColors.textTertiary)
            }
        }
        .padding(.vertical, 1)
        .contentShape(Rectangle())
        .tag(item)
    }
}

/// Grid membership, exposed to a row as an explicit control rather than by
/// overloading the click.
///
/// This used to be `GridSidebarSelection`, and while the grid was on screen it
/// silently changed what clicking a row *meant* — same rows, same gesture,
/// opposite outcome, switched by unlabelled state. Membership is now its own
/// affordance, and a click opens a session in every presentation.
struct GridMembership {
    let memberIDs: Set<UUID>
    let onToggle: (UUID) -> Void
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
    var gridMembership: GridMembership? = nil

    @State private var isHovering = false

    private var isGridMember: Bool {
        gridMembership?.memberIDs.contains(session.id) ?? false
    }

    /// Exactly one state wins — layering translucent tints on top of each
    /// other (or on top of whatever AppKit's own `.sidebar`-style selection
    /// paints on the row underneath, which no `.background` can occlude
    /// since it's drawn by a separate `NSTableRowView` layer) is what
    /// produced a doubled-up look. Painting our own opaque backdrop first
    /// (below) hides that native layer entirely, so this is the only thing
    /// that's ever visible.
    ///
    /// Attention outranks everything. It used to lose to grid membership and
    /// to "this row is open", so on a supervision dashboard a session blocked
    /// on a human stopped standing out the moment you put it in the grid.
    /// Membership is no longer a row tint at all — it has its own control —
    /// which also retires the hover state that painted healthy rows in the
    /// crash colour.
    private var rowFill: Color {
        if session.status == .waitingForInput || session.status == .crashed {
            return StatusPresentation.color(for: session.status).opacity(isSelected ? 0.26 : 0.14)
        }
        if isSelected { return FlotillaColors.surfaceElevated }
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
        // Inner padding: breathing room *inside* the border.
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background {
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(FlotillaColors.sidebar)
                .overlay {
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(rowFill)
                }
        }
        // Membership is drawn on the row's own chrome rather than added to its
        // contents: a border, with a checkmark straddling the corner. Nothing
        // is inserted into the row's layout, so the dense list keeps its
        // rhythm and non-members are completely unmarked.
        .overlay {
            if isGridMember {
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .strokeBorder(FlotillaColors.accent.opacity(0.8), lineWidth: 1.5)
            }
        }
        .overlay(alignment: .topTrailing) {
            if isGridMember {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(FlotillaColors.accent)
                    // A ring in the sidebar colour so the glyph reads as
                    // sitting *on* the border rather than beside it. Held
                    // inside the frame rather than offset out of it — with no
                    // horizontal padding left, anything outside gets clipped.
                    .background(FlotillaColors.sidebar, in: Circle())
                    .padding(.top, -5)
                    .padding(.trailing, 4)
                    .accessibilityHidden(true)
            }
        }
        // The gap between rows. Applied after the background and overlays —
        // before them it just grows the bordered box instead of separating one
        // box from the next.
        .padding(.vertical, 4)
        .accessibilityLabel(isGridMember ? "\(session.title), in grid" : session.title)
        .animation(.easeOut(duration: 0.1), value: isHovering)
        .onHover { isHovering = $0 }
        // While the grid is up a single click toggles membership (see
        // `FlotillaShell.handleSidebarSelectionChange`), so double-click is
        // what still opens the session — otherwise building a grid would cost
        // you the ability to open anything from the sidebar.
        .simultaneousGesture(
            TapGesture(count: 2).onEnded {
                guard gridMembership != nil else { return }
                onOpenSession(session.id)
            }
        )
        .listRowInsets(EdgeInsets())
        // The row's own background, spanning the whole cell rect rather than
        // just this view. `.sidebar` list style insets row *content* but paints
        // its selection across the full cell, so an opaque colour applied
        // inside the row could never reach the strip at either edge — which is
        // where the system blue kept showing. Selection is drawn by `rowFill`
        // instead, which is the lighter fill the rest of the app uses.
        .listRowBackground(FlotillaColors.sidebar)
        .modifier(SwipeToDeleteSession(
            accessibilityID: "SessionRow-\(session.title)-SwipeDelete",
            onCommit: { Task { await store.deleteSession(sessionID: session.id, deleteWorktree: false) } },
            onConfirm: { onRequestDelete(session.id) }
        ))
        .tag(SidebarItem.session(session.id))
        .accessibilityIdentifier(AXID.sessionRow(session.title))
        .contextMenu {
            Button("Open Session") {
                onOpenSession(session.id)
            }
            if let gridMembership {
                Button(isGridMember ? "Remove from Grid" : "Add to Grid") {
                    gridMembership.onToggle(session.id)
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

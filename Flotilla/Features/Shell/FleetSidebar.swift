import SwiftUI
import SessionKit
import DesignSystem

/// The navigator: search on top, then the fleet smart lists, then projects
/// with their sessions beneath them, then unassigned sessions, with a floating
/// New Session control over the list's lower-left corner.
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
    @State private var collapsedProjects: Set<UUID> = []

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
                    .autocorrectionDisabled()
                    .textContentType(nil)
                if !searchText.isEmpty {
                    Button(action: { searchText = "" }) {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 11))
                            .foregroundStyle(FlotillaColors.textSecondary)
                    }
                    .buttonStyle(.plain)
                }
                if store.projects.count > 1 {
                    Menu {
                        Button("Expand All") {
                            collapsedProjects.removeAll()
                            SidebarProjectCollapseState.save(collapsedProjects)
                        }
                        .accessibilityIdentifier(AXID.sidebarExpandAllProjects.rawValue)
                        Button("Collapse All") {
                            collapsedProjects = Set(store.projects.map(\.id))
                            SidebarProjectCollapseState.save(collapsedProjects)
                        }
                        .accessibilityIdentifier(AXID.sidebarCollapseAllProjects.rawValue)
                    } label: {
                        Image(systemName: "list.bullet.indent")
                            .font(.system(size: 11))
                            .foregroundStyle(FlotillaColors.textSecondary)
                    }
                    .menuStyle(.borderlessButton)
                    .fixedSize()
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
                gridMembership: gridMembership,
                collapsedProjects: $collapsedProjects
            )
            .onAppear { collapsedProjects = SidebarProjectCollapseState.load() }
            .overlay(alignment: .bottomLeading) {
                // The 36-point glass stays visually compact; its 44-point
                // frame preserves a comfortable pointer/accessibility target.
                Button(action: onCreateSession) {
                    Image(systemName: "plus")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(FlotillaColors.textPrimary)
                        .frame(width: 36, height: 36)
                        .glassEffect(.regular.interactive(), in: .circle)
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .focusable(false)
                .focusEffectDisabled()
                .help("Create new session (⌘N)")
                .accessibilityLabel("New Session")
                .accessibilityIdentifier("NewSessionButton")
                .padding(.leading, 10)
                .padding(.bottom, 10)
            }
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
    @Binding var collapsedProjects: Set<UUID>
    @State private var editingIconProject: Project? = nil

    private var filtered: SidebarFilterResult { store.sidebarFilter(matching: searchText) }

    private var isSearching: Bool {
        !searchText.trimmingCharacters(in: .whitespaces).isEmpty
    }

    var body: some View {
        List(selection: $selection) {
            // Home is the only standing destination left up here. The three
            // smart lists and All Sessions used to sit beside it, five rows
            // deep, restating counts every session row already carries — and
            // all four are still one keystroke away in the Go menu (⌘1, ⌘2,
            // and a button apiece).
            if !isSearching {
                Section {
                    NavigatorRow(item: .overview, title: "Home", systemImage: "house")
                        .accessibilityIdentifier(AXID.sidebarOverview.rawValue)
                }
            }

            if filtered.projects.isEmpty && filtered.generalSessions.isEmpty {
                Text(isSearching ? "No matches" : "No sessions yet")
                    .foregroundStyle(.secondary)
            }

            ForEach(filtered.projects) { project in
                let projectSessions = filtered.sessionsByProject[project.id] ?? []
                let isCollapsed = collapsedProjects.contains(project.id)
                // No header: the project's own row is the header, and unlike a
                // `Section` header it can be selected to open the workspace.
                // Its own chevron button toggles collapse without touching
                // the row's selection tag.
                Section {
                    ProjectHeaderRow(
                        project: project,
                        isCollapsed: isCollapsed,
                        onToggleCollapse: { toggleCollapsed(project.id) }
                    )
                    .contentShape(Rectangle())
                    .tag(SidebarItem.project(project.id))
                    .listRowInsets(EdgeInsets())
                    .listRowBackground(FlotillaColors.sidebar)
                    .accessibilityIdentifier(AXID.sidebarProjectRow.rawValue + project.name)
                    .contextMenu {
                        Button("Change Icon & Color…") {
                            editingIconProject = project
                        }
                        Menu("Accent Color") {
                            Button("Auto / Default") {
                                store.updateProjectAccentColor(id: project.id, accentColor: nil)
                            }
                            Divider()
                            ForEach(ProjectIconPickerSheet.presetAccentColors) { preset in
                                Button {
                                    store.updateProjectAccentColor(id: project.id, accentColor: preset.hex)
                                } label: {
                                    HStack {
                                        Text(preset.name)
                                        if isCurrentAccent(project: project, hex: preset.hex) {
                                            Image(systemName: "checkmark")
                                        }
                                    }
                                }
                            }
                        }
                        if project.icon != nil {
                            Button("Remove Icon") {
                                store.updateProjectIcon(id: project.id, icon: nil)
                            }
                        }
                        Divider()
                        Button("Reveal in Finder") {
                            NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: project.rootPath.path)
                        }
                    }

                    if !isCollapsed {
                        ForEach(projectSessions) { session in
                            sessionRow(session)
                        }
                    }
                }
            }

            if !filtered.generalSessions.isEmpty {
                Section("General") {
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
        .sheet(item: $editingIconProject) { project in
            ProjectIconPickerSheet(
                project: project,
                onSave: { newIcon, newAccent in
                    store.updateProjectIdentity(id: project.id, icon: newIcon, accentColor: newAccent)
                },
                onDismiss: {
                    editingIconProject = nil
                }
            )
        }
    }

    private func isCurrentAccent(project: Project, hex: String) -> Bool {
        guard let current = project.accentColor else { return false }
        let c1 = current.trimmingCharacters(in: CharacterSet(charactersIn: "#")).uppercased()
        let c2 = hex.trimmingCharacters(in: CharacterSet(charactersIn: "#")).uppercased()
        return c1 == c2
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

    private func toggleCollapsed(_ id: UUID) {
        if collapsedProjects.contains(id) { collapsedProjects.remove(id) } else { collapsedProjects.insert(id) }
        SidebarProjectCollapseState.save(collapsedProjects)
    }
}

/// Persists which sidebar project sections are folded away. Absent means
/// expanded, so a project created after this was last saved starts open.
enum SidebarProjectCollapseState {
    private static let defaultsKey = "sidebar.collapsedProjects"

    static func load(defaults: UserDefaults = .standard) -> Set<UUID> {
        let strings = defaults.stringArray(forKey: defaultsKey) ?? []
        return Set(strings.compactMap(UUID.init))
    }

    static func save(_ ids: Set<UUID>, defaults: UserDefaults = .standard) {
        defaults.set(ids.map(\.uuidString), forKey: defaultsKey)
    }
}

// MARK: - Navigator row

/// A standing destination row: icon, label. Home is the only one left — the
/// smart lists and All Sessions moved out of the navigator entirely, and a
/// project draws its own header (`ProjectHeaderRow`) rather than borrowing
/// this one, which is what kept its title at 12pt under 13pt session titles.
private struct NavigatorRow: View {
    let item: SidebarItem
    let title: String
    var systemImage: String = "folder.fill"

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: systemImage)
                .font(.system(size: 12))
                .frame(width: 18)
                .foregroundStyle(FlotillaColors.textSecondary)

            Text(title)
                .font(.system(size: 13, weight: .medium))
                .lineLimit(1)
                .truncationMode(.middle)

            Spacer(minLength: 4)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 2)
        .contentShape(Rectangle())
        .tag(item)
    }
}

/// A project's line in the navigator, and the header for the sessions beneath
/// it.
///
/// It used to borrow `NavigatorRow`: a 16pt mark and a 12pt title, sitting
/// over 13pt session titles and their 28pt provider tiles, so the group read
/// as smaller than the things inside it. Home draws its project cards at 38pt
/// beside an 18pt title; this is the same identity at navigator scale.
private struct ProjectHeaderRow: View {
    let project: Project
    let isCollapsed: Bool
    let onToggleCollapse: () -> Void

    private var tint: Color { ProjectMark.tint(for: project) }

    /// Home-relative, the way every other Mac app shows a location, and the
    /// same abbreviation `SessionSidebarRow` puts on its tooltip.
    private var homeRelativePath: String {
        project.rootPath.path.replacingOccurrences(
            of: FileManager.default.homeDirectoryForCurrentUser.path,
            with: "~"
        )
    }

    var body: some View {
        HStack(spacing: 10) {
            // Its own `Button`, so it consumes the click instead of selecting
            // the row — collapsing a project must not navigate to it.
            Button(action: onToggleCollapse) {
                Image(systemName: "chevron.right")
                    .font(.system(size: 9, weight: .bold))
                    .rotationEffect(.degrees(isCollapsed ? 0 : 90))
                    .frame(width: 10)
                    .foregroundStyle(FlotillaColors.textTertiary)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(isCollapsed ? "Expand \(project.name)" : "Collapse \(project.name)")
            .accessibilityIdentifier(AXID.sidebarProjectCollapseToggle(project.name))

            ProjectMark(project: project, size: 28)

            VStack(alignment: .leading, spacing: 1) {
                Text(project.name)
                    .font(.system(size: 15, weight: .bold))
                    .foregroundStyle(FlotillaColors.textPrimary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(homeRelativePath)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(FlotillaColors.textTertiary)
                    .lineLimit(1)
                    // Head-truncated: the last components identify the
                    // project, the first ones are the same for every row.
                    .truncationMode(.head)
            }

            Spacer(minLength: 4)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 6)
        // In the project's own accent, so the divider says whose sessions
        // follow rather than just where the group starts.
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(tint.opacity(0.45))
                .frame(height: 1)
        }
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

    /// Branch and worktree path, abbreviated with `~` the way every other Mac
    /// app shows a home-relative location.
    private var locationDescription: String {
        let path = (session.worktree?.worktreePath ?? session.workingDirectory)
            .path
            .replacingOccurrences(
                of: FileManager.default.homeDirectoryForCurrentUser.path,
                with: "~"
            )
        guard let branch = session.worktree?.branchName else { return path }
        return "\(BranchNaming.displayName(for: branch))\n\(path)"
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
        // The worktree path, which is otherwise only in the delete sheet and
        // behind right-click → Copy Path. Costs no screen space, so it does
        // not have to compete with the branch and agent already in the window
        // subtitle.
        .help(locationDescription)
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
    let accessibilityID: String
    let onConfirm: () -> Void

    func body(content: Content) -> some View {
        content.swipeActions(edge: .trailing, allowsFullSwipe: true) {
            Button(role: .destructive, action: onConfirm) {
                Label("Delete", systemImage: "trash")
            }
            .accessibilityIdentifier(accessibilityID)
        }
    }
}

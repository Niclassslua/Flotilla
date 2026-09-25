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
    let isHomeSelected: Bool
    let onSelectHome: () -> Void
    let onOpenSession: (UUID) -> Void
    let onRequestDelete: (UUID) -> Void
    let onCreateSession: () -> Void
    /// Whether the grid is the current presentation, which is the only context
    /// where a row's grid-membership control means anything. It no longer
    /// changes what *clicking* a row does — see `SessionSidebarRow`.
    var gridMembership: GridMembership? = nil
    @State private var collapsedProjects: Set<UUID> = []
    @Environment(\.flotillaLiquidGlassEnabled) private var liquidGlassEnabled

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
            .flotillaLiquidSurface(
                FlotillaColors.surfaceElevated.opacity(liquidGlassEnabled ? 0.35 : 0.5),
                cornerRadius: liquidGlassEnabled ? 9 : 6,
                glassTintOpacity: FlotillaGlassTint.sidebar
            )
            .padding(.horizontal, 10)
            .padding(.top, 10)
            .padding(.bottom, 6)

            if searchText.trimmingCharacters(in: .whitespaces).isEmpty {
                Button(action: onSelectHome) {
                    NavigatorRow(title: "Home", systemImage: "house", isSelected: isHomeSelected)
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier(AXID.sidebarOverview.rawValue)
                .padding(.horizontal, 10)
                .padding(.bottom, 8)
            }

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
                newSessionFAB
            }
        }
        // Continues under the traffic lights: the window toolbar draws no
        // band of its own in glass mode (see `FlotillaShell`).
        .flotillaLiquidSurface(
            FlotillaColors.sidebar,
            glassTintOpacity: FlotillaGlassTint.sidebar,
            stableTintOpacity: 0.12,
            ignoresSafeAreaEdges: .top
        )
    }

    private var newSessionFAB: some View {
        Button(action: onCreateSession) {
            Color.clear
                .frame(width: 36, height: 36)
                .flotillaChromeCircle()
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        // Paint the symbol above the glass surface so it retains full contrast.
        .overlay {
            Image(systemName: "plus")
                .font(.system(size: 14, weight: .bold))
                .foregroundStyle(FlotillaColors.textPrimary)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
        }
        .focusable(false)
        .focusEffectDisabled()
        .help("Create new session (⌘N)")
        .accessibilityLabel("New Session")
        .accessibilityIdentifier("NewSessionButton")
        .padding(.leading, 10)
        .padding(.bottom, 10)
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
    @Environment(\.flotillaLiquidGlassEnabled) private var liquidGlassEnabled
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
                        sessionCount: projectSessions.count,
                        onToggleCollapse: { toggleCollapsed(project.id) }
                    )
                    .contentShape(Rectangle())
                    .tag(SidebarItem.project(project.id))
                    .listRowInsets(EdgeInsets())
                    .listRowBackground(liquidGlassEnabled ? Color.clear : FlotillaColors.sidebar)
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
        .background(Color.clear)
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

/// Home's standalone button label, outside the List's native selection layer.
private struct NavigatorRow: View {
    @Environment(\.flotillaLiquidGlassEnabled) private var liquidGlassEnabled
    @Environment(\.appearsActive) private var appearsActive
    let title: String
    var systemImage: String = "folder.fill"
    let isSelected: Bool

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
        .padding(.horizontal, liquidGlassEnabled ? 8 : 0)
        .padding(.vertical, liquidGlassEnabled ? 7 : 2)
        .flotillaLiquidSurface(
            liquidGlassEnabled
                ? FlotillaColors.surfaceElevated.opacity(0.35)
                : (isSelected ? FlotillaColors.surfaceElevated : .clear),
            cornerRadius: 9,
            glassTintOpacity: isSelected && appearsActive ? 0.32 : FlotillaGlassTint.sidebar
        )
        .contentShape(Rectangle())
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
    @Environment(\.flotillaLiquidGlassEnabled) private var liquidGlassEnabled
    let project: Project
    let isCollapsed: Bool
    let sessionCount: Int
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

            ProjectMark(project: project, size: liquidGlassEnabled ? 20 : 28)

            VStack(alignment: .leading, spacing: 1) {
                Text(project.name)
                    .font(.system(size: liquidGlassEnabled ? 13 : 15, weight: .semibold))
                    .foregroundStyle(FlotillaColors.textPrimary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                if !liquidGlassEnabled {
                    Text(homeRelativePath)
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(FlotillaColors.textTertiary)
                        .lineLimit(1)
                        .truncationMode(.head)
                }
            }

            Spacer(minLength: 4)
            if liquidGlassEnabled {
                Text(sessionCount, format: .number)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(FlotillaColors.textTertiary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, liquidGlassEnabled ? 10 : 0)
        .padding(.vertical, liquidGlassEnabled ? 11 : 6)
        // In the project's own accent, so the divider says whose sessions
        // follow rather than just where the group starts.
        .overlay(alignment: .bottom) {
            if !liquidGlassEnabled {
                Rectangle()
                    .fill(tint.opacity(0.45))
                    .frame(height: 1)
            }
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
    @Environment(\.flotillaLiquidGlassEnabled) private var liquidGlassEnabled
    @Environment(\.appearsActive) private var appearsActive
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

    /// In the key window, an opaque list-row background hides AppKit's blue
    /// highlight so the rounded neutral selection can take its place. When
    /// inactive, the system's subdued selection should show through instead.
    private var rowFill: Color {
        if liquidGlassEnabled {
            if isSelected { return appearsActive ? FlotillaColors.surfaceElevated : .clear }
            if isHovering { return FlotillaColors.textPrimary.opacity(0.07) }
            return .clear
        }
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
            isSelected: isSelected,
            onTap: { onOpenSession(session.id) },
            onDelete: { onRequestDelete(session.id) },
            onRestart: { store.restartSession(sessionID: session.id) },
            onRevealInFinder: { },
            onCopyPath: { },
            onCopyBranch: { },
            terminal: { EmptyView() }
        )
        // Inner padding: breathing room *inside* the border.
        .padding(.horizontal, liquidGlassEnabled ? 12 : 8)
        .padding(.vertical, liquidGlassEnabled ? 1 : 4)
        .background {
            if liquidGlassEnabled {
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(rowFill)
            } else {
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(FlotillaColors.sidebar)
                    .overlay {
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .fill(rowFill)
                    }
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
        .padding(.vertical, liquidGlassEnabled ? 1 : 4)
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
        // Cover the active blue selection across the full cell. In an inactive
        // window, let AppKit draw its own muted highlight without a dark box.
        .listRowBackground(
            liquidGlassEnabled && (!isSelected || !appearsActive) ? Color.clear : FlotillaColors.sidebar
        )
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

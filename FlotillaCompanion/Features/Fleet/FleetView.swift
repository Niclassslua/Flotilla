import SwiftUI
import SessionKit
import DesignSystem
import CompanionKit

/// One Mac's sessions: **Needs you** pinned on top, then grouped by project.
struct FleetView: View {
    let macID: MacHost.ID

    @Environment(CompanionStore.self) private var store
    @State private var isCreating = false
    @State private var pendingDelete: CompanionSession?
    @State private var collapsedProjects: Set<String> = []

    var body: some View {
        let mac = store.mac(macID)
        let isActionable = store.isActionable(macID: macID)
        let sessions = store.sessions(on: macID)
        let needsYou = sessions.filter(\.needsYou)
        let groups = projectGroups(sessions.filter { !$0.needsYou })

        List {
            if sessions.isEmpty {
                ContentUnavailableView("No Sessions", systemImage: "square.stack", description: Text("Sessions created on this Mac or from here appear in this list."))
                    .listRowBackground(Color.clear)
            }
            if !needsYou.isEmpty {
                Section {
                    ForEach(needsYou) { row(for: $0, isActionable: isActionable) }
                } header: {
                    Label("Needs you", systemImage: "exclamationmark.circle.fill")
                        .foregroundStyle(FlotillaColors.accent)
                }
            }
            ForEach(groups, id: \.name) { group in
                let isCollapsed = collapsedProjects.contains(group.name)
                Section {
                    if !isCollapsed {
                        ForEach(group.sessions) { row(for: $0, isActionable: isActionable) }
                    }
                } header: {
                    projectHeader(group.name, isCollapsed: isCollapsed)
                }
            }
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .background(FlotillaColors.canvas)
        .animation(.snappy, value: sessions.map(\.id))
        .animation(.snappy, value: needsYou.map(\.id))
        .safeAreaInset(edge: .top, spacing: 0) {
            if let mac, !mac.isReachable {
                UnreachableBanner(mac: mac, asOf: store.fleetReceivedAt(macID))
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .animation(.snappy, value: mac?.isReachable)
        .navigationTitle(mac?.name ?? "Mac")
        .toolbar {
            #if DEBUG
            ToolbarItem(placement: .topBarTrailing) { ScenarioMenu() }
            #endif
            ToolbarItem(placement: .topBarTrailing) {
                Button("New Session", systemImage: "plus") { isCreating = true }
                    .disabled(!isActionable)
            }
            if groups.count > 1 {
                ToolbarItem(placement: .topBarLeading) {
                    Menu("Project Sections", systemImage: "list.bullet.indent") {
                        Button("Expand All", systemImage: "chevron.down") { setAllCollapsed(false, groups: groups) }
                        Button("Collapse All", systemImage: "chevron.right") { setAllCollapsed(true, groups: groups) }
                    }
                }
            }
        }
        .sheet(isPresented: $isCreating) {
            CreateSessionSheet(macID: macID) { newID in
                store.path.append(.session(newID))
            }
        }
        .onAppear { collapsedProjects = store.collapsedProjects(on: macID) }
    }

    private func projectHeader(_ name: String, isCollapsed: Bool) -> some View {
        Button {
            withAnimation(.snappy) {
                if isCollapsed { collapsedProjects.remove(name) } else { collapsedProjects.insert(name) }
            }
            store.setCollapsedProjects(collapsedProjects, on: macID)
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "chevron.right")
                    .font(.caption2.weight(.semibold))
                    .rotationEffect(.degrees(isCollapsed ? 0 : 90))
                Text(name)
            }
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("FleetView.ProjectHeader")
        .accessibilityValue(isCollapsed ? "Collapsed" : "Expanded")
    }

    private func setAllCollapsed(_ collapsed: Bool, groups: [(name: String, sessions: [CompanionSession])]) {
        withAnimation(.snappy) {
            collapsedProjects = collapsed ? Set(groups.map(\.name)) : []
        }
        store.setCollapsedProjects(collapsedProjects, on: macID)
    }

    @ViewBuilder
    private func row(for session: CompanionSession, isActionable: Bool) -> some View {
        let permission = firstPermission(of: session)
        NavigationLink(value: Route.session(session.id)) {
            SessionRowView(
                session: session,
                projectName: store.projectName(session.projectID, on: macID),
                latestLine: store.transcript(for: session.id).latestCompleteLine
            )
        }
        .listRowBackground(FlotillaColors.surface)
        // Anchored to this row (not the List) so on iPad the dialog pops up
        // over the row being deleted instead of near the top of the screen.
        .sessionDeleteDialog(session: $pendingDelete, matching: session)
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            Button("Delete", systemImage: "trash") { pendingDelete = session }
                .tint(FlotillaColors.danger)
                .disabled(!isActionable)
            if let permission {
                Button("Deny", systemImage: "xmark") {
                    Task { _ = await store.answer(permission.id, in: session.id, with: .deny) }
                }
                .tint(FlotillaColors.statusIdle)
                .disabled(!isActionable)
            }
        }
    }

    private func firstPermission(of session: CompanionSession) -> PendingInteraction? {
        guard let first = store.pendingInteractions(for: session.id).first, first.resolution == nil,
              case .permission = first.kind else { return nil }
        return first
    }

    private func projectGroups(_ sessions: [CompanionSession]) -> [(name: String, sessions: [CompanionSession])] {
        let grouped = Dictionary(grouping: sessions) { store.projectName($0.projectID, on: macID) }
        return grouped
            .map { (name: $0.key, sessions: $0.value.sorted { $0.updatedAt > $1.updatedAt }) }
            // General last; projects alphabetically.
            .sorted { lhs, rhs in
                if lhs.name == "General" { return false }
                if rhs.name == "General" { return true }
                return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
            }
    }
}

extension View {
    /// The Mac's delete choices as an iOS confirmation dialog, anchored to the
    /// row it's attached to so it pops up over the session being deleted
    /// (rather than at the top of the screen, which is what happens when the
    /// dialog is anchored to a container like the enclosing `List`).
    func sessionDeleteDialog(
        session: Binding<CompanionSession?>,
        matching rowSession: CompanionSession,
        onDeleted: @escaping () -> Void = {}
    ) -> some View {
        modifier(SessionDeleteDialog(session: session, rowSession: rowSession, onDeleted: onDeleted))
    }
}

/// Mirrors the Mac's `DeleteSessionSheet`: worktree sessions choose whether the
/// worktree goes too, and a live agent is called out.
private struct SessionDeleteDialog: ViewModifier {
    @Binding var session: CompanionSession?
    let rowSession: CompanionSession
    let onDeleted: () -> Void
    @Environment(CompanionStore.self) private var store

    func body(content: Content) -> some View {
        content.confirmationDialog(
            session.map { "Delete “\($0.title)”?" } ?? "",
            isPresented: Binding(
                get: { session?.id == rowSession.id },
                set: { if !$0 { session = nil } }
            ),
            titleVisibility: .visible,
            presenting: session
        ) { target in
            if target.hasWorktree {
                Button("Delete Session & Worktree", role: .destructive) { delete(target, removeWorktree: true) }
                Button("Keep Worktree, Delete Session Only") { delete(target, removeWorktree: false) }
            } else {
                Button("Delete Session", role: .destructive) { delete(target, removeWorktree: false) }
            }
            Button("Cancel", role: .cancel) {}
        } message: { target in
            Text(message(for: target))
        }
    }

    private func delete(_ target: CompanionSession, removeWorktree: Bool) {
        Task {
            await store.delete(target.id, removeWorktree: removeWorktree)
            onDeleted()
        }
    }

    private func message(for target: CompanionSession) -> String {
        var text = target.hasWorktree
            ? "Remove only Flotilla's session record, or also clean up its isolated worktree and branch from Git."
            : "Terminal history and session metadata will be permanently removed."
        if target.isProcessLive {
            text += "\n\nThis session's agent is still running. Deleting it stops the process immediately."
        }
        return text
    }
}

#Preview {
    NavigationStack { FleetView(macID: MockFixtures.MacID.studio) }
        .environment(CompanionStore(data: MockCompanionDataSource()))
        .preferredColorScheme(.dark)
}

#Preview("Unreachable") {
    NavigationStack { FleetView(macID: MockFixtures.MacID.macBook) }
        .environment(CompanionStore(data: MockCompanionDataSource()))
        .preferredColorScheme(.dark)
}

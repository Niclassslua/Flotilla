import SwiftUI
import SessionKit
import DesignSystem

struct GridView: View {
    let store: AppStore
    let terminalManager: TerminalManager
    @Binding var activeSessionID: UUID?
    @Binding var minimumTileWidth: Double
    let openSession: (UUID) -> Void
    @State private var selectedProjectID: UUID?

    private var visibleSessions: [Session] {
        guard let selectedProjectID else { return store.sessions }
        return store.sessions.filter { $0.projectID == selectedProjectID }
    }

    var body: some View {
        VStack(spacing: 0) {
            gridToolbar
            Divider()

            if visibleSessions.isEmpty {
                ContentUnavailableView(
                    store.sessions.isEmpty ? "No Live Sessions" : "No Sessions in This Project",
                    systemImage: "square.grid.2x2",
                    description: Text(store.sessions.isEmpty
                        ? "Launch sessions to assemble a live grid."
                        : "Choose another project or return to all sessions.")
                )
                .accessibilityIdentifier("GridEmptyState")
            } else {
                GeometryReader { proxy in
                    let metrics = gridMetrics(for: proxy.size)
                    LazyVGrid(columns: metrics.columns, spacing: 12) {
                        ForEach(visibleSessions) { session in
                            GridTileView(
                                session: session,
                                store: store,
                                terminalManager: terminalManager,
                                isActive: activeSessionID == session.id,
                                onActivate: { activeSessionID = session.id },
                                onOpenSession: { openSession(session.id) }
                            )
                            .frame(height: metrics.tileHeight)
                        }
                    }
                    .padding(12)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                }
                .accessibilityIdentifier("GridView")
            }
        }
        .background(FlotillaColors().canvas)
        .onAppear(perform: ensureActiveSession)
        .onChange(of: visibleSessions.map(\.id)) {
            ensureActiveSession()
        }
    }

    private var gridToolbar: some View {
        HStack(spacing: 12) {
            Label("Session Grid", systemImage: "square.grid.2x2.fill")
                .font(.headline)
            Text("\(visibleSessions.count) sessions")
                .font(.caption)
                .foregroundStyle(.secondary)
                .monospacedDigit()

            Menu {
                Button("All projects") { selectedProjectID = nil }
                Divider()
                ForEach(store.projects) { project in
                    Button(project.name) { selectedProjectID = project.id }
                }
            } label: {
                Label(selectedProjectName, systemImage: "line.3.horizontal.decrease.circle")
            }
            Spacer()
            Image(systemName: "rectangle.grid.3x2")
                .foregroundStyle(.secondary)
            Slider(value: $minimumTileWidth, in: 280...560, step: 20)
                .frame(width: 120)
                .help("Grid tile size")
                .accessibilityLabel("Grid tile size")
            Image(systemName: "rectangle.grid.2x2")
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .background(FlotillaColors().surface)
    }

    private var selectedProjectName: String {
        guard let selectedProjectID,
              let project = store.projects.first(where: { $0.id == selectedProjectID }) else {
            return "All projects"
        }
        return project.name
    }

    private func ensureActiveSession() {
        guard !visibleSessions.isEmpty else {
            activeSessionID = nil
            return
        }
        if let activeSessionID,
           visibleSessions.contains(where: { $0.id == activeSessionID }) {
            return
        }
        if let selectedSessionID = store.selectedSessionID,
           visibleSessions.contains(where: { $0.id == selectedSessionID }) {
            activeSessionID = selectedSessionID
        } else {
            activeSessionID = visibleSessions[0].id
        }
    }

    private func gridMetrics(for size: CGSize) -> GridMetrics {
        let availableWidth = max(1, size.width - 24)
        let availableHeight = max(1, size.height - 24)
        let requestedMinimumWidth = max(280, minimumTileWidth)
        let maximumColumns = max(1, Int((availableWidth + 12) / (requestedMinimumWidth + 12)))
        let columnCount = min(visibleSessions.count, maximumColumns)
        let rowCount = max(1, Int(ceil(Double(visibleSessions.count) / Double(columnCount))))
        let tileHeight = max(1, (availableHeight - CGFloat(rowCount - 1) * 12) / CGFloat(rowCount))
        let columns = Array(
            repeating: GridItem(.flexible(minimum: 1), spacing: 12),
            count: columnCount
        )
        return GridMetrics(columns: columns, tileHeight: tileHeight)
    }
}

private struct GridMetrics {
    let columns: [GridItem]
    let tileHeight: CGFloat
}

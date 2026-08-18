import SwiftUI
import SessionKit
import DesignSystem

struct WorkspaceInspector: View {
    @Bindable var registry: SessionWorkspaceRegistry
    let session: Session
    @Binding var tab: InspectorTab
    let store: AppStore

    var body: some View {
        VStack(spacing: 0) {
            // Tab picker
            Picker("Inspector", selection: $tab) {
                ForEach(InspectorTab.allCases) { tab in
                    Label(tab.title, systemImage: tab.systemImage).tag(tab)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(FlotillaColors.surface)
            .overlay(alignment: .bottom) { Divider() }

            // Tab content
            Group {
                switch tab {
                case .changes:
                    changesContent
                case .files:
                    filesContent
                case .instructions:
                    instructionsContent
                case .details:
                    detailsContent
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(FlotillaColors.canvas)
        .onDisappear {
            registry.releaseSession(session.id)
        }
    }

    @ViewBuilder
    private var changesContent: some View {
        let vm = registry.diffViewModel(for: session)
        DiffPanelView(viewModel: vm)
    }

    @ViewBuilder
    private var filesContent: some View {
        let vm = registry.fileBrowserViewModel(for: session)
        FileBrowserView(viewModel: vm)
    }

    @ViewBuilder
    private var instructionsContent: some View {
        let vm = registry.rulesViewModel(for: session)
        RulesPanelView(viewModel: vm)
    }

    @ViewBuilder
    private var detailsContent: some View {
        SessionDetailsView(session: session, store: store)
    }
}

struct SessionDetailsView: View {
    let session: Session
    let store: AppStore

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(session.title)
                        .font(.headline)
                    Text(session.goal)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(3)
                }

                Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 9) {
                    detailRow("Status", StatusPresentation.label(for: session.status))
                    detailRow("Agent", session.agent.displayName)
                    detailRow("Branch", session.worktree?.branchName ?? "—")
                    detailRow("Session ID", session.id.uuidString)
                    detailRow("Created", session.createdAt.formatted(date: .abbreviated, time: .shortened))
                    detailRow("Last activity", session.lastActiveAt.formatted(date: .abbreviated, time: .shortened))
                }

                VStack(alignment: .leading, spacing: 3) {
                    Text("Working directory")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.secondary)
                    let worktreePath = session.worktree?.worktreePath ?? session.workingDirectory
                    Text(worktreePath.path)
                        .font(.caption.monospaced())
                        .textSelection(.enabled)
                        .lineLimit(3)
                        .truncationMode(.middle)
                }
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(FlotillaColors.canvas)
        .accessibilityIdentifier("SessionDetailsView")
    }

    private func detailRow(_ label: String, _ value: String) -> some View {
        GridRow {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.caption.monospaced())
                .lineLimit(1)
                .truncationMode(.middle)
                .textSelection(.enabled)
        }
    }
}
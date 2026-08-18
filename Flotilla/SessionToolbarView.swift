import SwiftUI
import Observation
import SessionKit
import GitKit
import DesignSystem

@Observable
@MainActor
private final class SessionToolbarViewModel {
    private let session: Session
    private let gitService: any GitServiceProtocol
    private(set) var branchName: String

    init(session: Session, gitService: any GitServiceProtocol) {
        self.session = session
        self.gitService = gitService
        self.branchName = session.worktree?.branchName ?? "—"
    }

    func loadBranch() async {
        guard session.projectID != nil, session.worktree == nil else { return }
        do {
            branchName = try await gitService.currentBranch(at: session.workingDirectory)
        } catch {
            branchName = "No branch"
        }
    }
}

struct SessionToolbarView: View {
    let session: Session
    let project: Project?
    @Binding var selectedLens: SessionLens
    @Binding var isChangesInspectorOpen: Bool
    @State private var viewModel: SessionToolbarViewModel
    @State private var isShowingDetails = false

    init(
        session: Session,
        project: Project?,
        gitService: any GitServiceProtocol,
        selectedLens: Binding<SessionLens>,
        isChangesInspectorOpen: Binding<Bool>
    ) {
        self.session = session
        self.project = project
        _selectedLens = selectedLens
        _isChangesInspectorOpen = isChangesInspectorOpen
        _viewModel = State(initialValue: SessionToolbarViewModel(session: session, gitService: gitService))
    }

    var body: some View {
        HStack(spacing: 8) {
            Text(project?.name ?? "Quick session")
                .font(.caption.weight(.medium))
                .foregroundStyle(FlotillaColors.textPrimary)
                .lineLimit(1)

            Text("/")
                .foregroundStyle(.tertiary)

            Text(session.title)
                .font(.caption.weight(.medium))
                .lineLimit(1)

            agentMetadata

            compactMetadata(
                icon: "arrow.triangle.branch",
                value: viewModel.branchName,
                tint: FlotillaColors.statusWorking,
                accessibilityIdentifier: "SessionToolbar.Branch"
            )

            compactMetadata(
                icon: session.worktree == nil ? "shippingbox" : "square.stack.3d.up",
                value: URL(fileURLWithPath: worktreePath).lastPathComponent,
                tint: .secondary,
                accessibilityIdentifier: "SessionToolbar.Path",
                accessibilityValue: worktreePath
            )
            .layoutPriority(-1)

            Spacer(minLength: 6)

            HStack(spacing: 2) {
                ForEach(SessionLens.allCases) { lens in
                    toolbarButton(
                        systemImage: lens.systemImage,
                        help: lens.title,
                        isSelected: selectedLens == lens,
                        accessibilityIdentifier: "Session.Lens.\(lens.rawValue)"
                    ) {
                        selectedLens = lens
                    }
                }

                Divider()
                    .frame(height: 18)
                    .padding(.horizontal, 3)

                toolbarButton(
                    systemImage: "sidebar.right",
                    help: "Toggle Git changes sidebar",
                    isSelected: isChangesInspectorOpen,
                    accessibilityIdentifier: "Session.GitInspectorButton"
                ) {
                    isChangesInspectorOpen.toggle()
                }

                toolbarButton(systemImage: "doc.on.doc", help: "Copy working directory") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(worktreePath, forType: .string)
                }

                toolbarButton(systemImage: "folder", help: "Reveal in Finder") {
                    NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: worktreePath)])
                }

                toolbarButton(
                    systemImage: "info.circle",
                    help: "Session details",
                    accessibilityIdentifier: "SessionToolbar.DetailsButton"
                ) {
                    isShowingDetails.toggle()
                }
                .popover(isPresented: $isShowingDetails, arrowEdge: .bottom) {
                    SessionDetailsPopover(
                        session: session,
                        branchName: viewModel.branchName,
                        workingDirectory: worktreePath
                    )
                }
            }

            HStack(spacing: 5) {
                StatusBadge(session.status, variant: .compact)
                Text(StatusPresentation.label(for: session.status))
                    .font(.caption2.weight(.medium))
            }
            .padding(.leading, 3)
            .accessibilityIdentifier("SessionToolbar.Status")
        }
        .padding(.horizontal, 12)
        .frame(height: 44)
        .background(FlotillaColors.surface)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(FlotillaColors.separator)
                .frame(height: 1)
        }
        .fixedSize(horizontal: false, vertical: true)
        .task(id: session.id) { await viewModel.loadBranch() }
    }

    private var agentMetadata: some View {
        HStack(spacing: 4) {
            ProviderLogo(agent: session.agent)
                .frame(width: 11, height: 11)
                .accessibilityHidden(true)
            Text(session.agent.displayName)
                .font(.caption2.monospaced())
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
                .accessibilityIdentifier("SessionToolbar.Agent")
        }
    }

    private func compactMetadata(
        icon: String,
        value: String,
        tint: Color,
        accessibilityIdentifier: String,
        accessibilityValue: String? = nil
    ) -> some View {
        HStack(spacing: 4) {
            Image(systemName: icon)
                .font(.caption2)
                .foregroundStyle(tint)
                .accessibilityHidden(true)
            Text(value)
                .font(.caption2.monospaced())
                .foregroundStyle(tint)
                .lineLimit(1)
                .truncationMode(.middle)
                .accessibilityValue(accessibilityValue ?? value)
                .accessibilityIdentifier(accessibilityIdentifier)
        }
    }

    private func toolbarButton(
        systemImage: String,
        help: String,
        isSelected: Bool = false,
        accessibilityIdentifier: String? = nil,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(isSelected ? Color.primary : Color.secondary)
                .frame(width: 28, height: 28)
                .contentShape(.rect)
                .background(
                    isSelected ? FlotillaColors.surfaceElevated : Color.clear,
                    in: .rect(cornerRadius: 5)
                )
        }
        .buttonStyle(.plain)
        .contentShape(.rect)
        .accessibilityIdentifier(accessibilityIdentifier ?? systemImage)
        .accessibilityLabel(help)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .help(help)
    }

    private var worktreePath: String {
        (session.worktree?.worktreePath ?? project?.rootPath ?? session.workingDirectory).path
    }
}

private struct SessionDetailsPopover: View {
    let session: Session
    let branchName: String
    let workingDirectory: String

    var body: some View {
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
                detailRow("Branch", branchName)
                detailRow("Session ID", session.id.uuidString)
                detailRow("Created", session.createdAt.formatted(date: .abbreviated, time: .shortened))
                detailRow("Last activity", session.lastActiveAt.formatted(date: .abbreviated, time: .shortened))
            }

            VStack(alignment: .leading, spacing: 3) {
                Text("Working directory")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
                Text(workingDirectory)
                    .font(.caption.monospaced())
                    .textSelection(.enabled)
                    .lineLimit(3)
                    .truncationMode(.middle)
            }
        }
        .padding(16)
        .frame(width: 390)
        .accessibilityIdentifier("SessionDetailsPopover")
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
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
    @Binding var selectedSurface: SessionSurface
    @Binding var isGitInspectorPresented: Bool
    @State private var viewModel: SessionToolbarViewModel
    @State private var isShowingDetails = false

    init(
        session: Session,
        project: Project?,
        gitService: any GitServiceProtocol,
        selectedSurface: Binding<SessionSurface>,
        isGitInspectorPresented: Binding<Bool>
    ) {
        self.session = session
        self.project = project
        _selectedSurface = selectedSurface
        _isGitInspectorPresented = isGitInspectorPresented
        _viewModel = State(initialValue: SessionToolbarViewModel(session: session, gitService: gitService))
    }

    var body: some View {
        HStack(spacing: 8) {
            Text(project?.name ?? "Quick session")
                .font(.caption.weight(.medium))
                .foregroundStyle(FlotillaPalette.cyan)
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
                tint: FlotillaPalette.signal,
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
                ForEach(SessionSurface.allCases) { surface in
                    toolbarButton(
                        systemImage: surface.systemImage,
                        help: surface.title,
                        isSelected: selectedSurface == surface,
                        accessibilityIdentifier: "Session.Surface.\(surface.rawValue)"
                    ) {
                        selectedSurface = surface
                    }
                }

                Divider()
                    .frame(height: 18)
                    .padding(.horizontal, 3)

                toolbarButton(
                    systemImage: "sidebar.right",
                    help: "Toggle Git changes sidebar",
                    isSelected: isGitInspectorPresented,
                    accessibilityIdentifier: "Session.GitInspectorButton"
                ) {
                    isGitInspectorPresented.toggle()
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
                StatusIndicator(
                    color: StatusPresentation.color(for: session.status),
                    label: StatusPresentation.label(for: session.status),
                    pulses: session.status == .working
                )
                Text(StatusPresentation.label(for: session.status))
                    .font(.caption2.weight(.medium))
            }
            .padding(.leading, 3)
            .accessibilityIdentifier("SessionToolbar.Status")
        }
        .padding(.horizontal, 12)
        .frame(height: 44)
        .background(FlotillaPalette.panel)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(FlotillaPalette.subtleStroke)
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
                    isSelected ? FlotillaPalette.elevated : Color.clear,
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

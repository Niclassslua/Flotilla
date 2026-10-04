import SwiftUI
import SessionKit
import GitKit
import DesignSystem

/// A project's Issues surface: its open GitHub issues on the left, the chosen
/// one on the right — rendered body, the sessions already working on it, and
/// Start Session to put an agent on it.
struct ProjectIssuesView: View {
    let project: Project
    let store: AppStore
    let openSession: (UUID) -> Void
    @Environment(\.workspaceNavigator) private var navigator
    @Environment(\.openURL) private var openURL
    @State private var viewModel: ProjectIssuesViewModel

    init(project: Project, store: AppStore, openSession: @escaping (UUID) -> Void) {
        self.project = project
        self.store = store
        self.openSession = openSession
        _viewModel = State(initialValue: ProjectIssuesViewModel(ghService: store.ghService, repository: project.rootPath))
    }

    private var projectSessions: [Session] {
        store.sessions.filter { $0.projectID == project.id }
    }

    var body: some View {
        Group {
            if store.ghService == nil {
                unavailable("GitHub CLI Not Found", "Install gh and sign in with `gh auth login` to see this project's issues.", systemImage: "terminal")
            } else {
                HSplitView {
                    VStack(spacing: 0) {
                        listControls
                        Divider()
                        list
                    }
                    .frame(minWidth: 340, idealWidth: 460, maxHeight: .infinity)

                    if let number = viewModel.selectedNumber,
                       let issue = viewModel.issues.first(where: { $0.number == number }) {
                        detail(issue)
                            .frame(minWidth: FlotillaLayoutWidth.inspectorMin, idealWidth: 600, maxHeight: .infinity)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .flotillaLiquidSurface(FlotillaColors.canvas, glassTintOpacity: FlotillaGlassTint.detail)
        .task(id: viewModel.query) {
            if viewModel.hasLoaded {
                try? await Task.sleep(for: .milliseconds(300))
                guard !Task.isCancelled else { return }
            }
            await viewModel.load()
            if viewModel.selectedNumber == nil {
                viewModel.selectedNumber = viewModel.visibleIssues(sessions: projectSessions).first?.number
            }
        }
        .task(id: viewModel.selectedNumber) {
            if let number = viewModel.selectedNumber { await viewModel.loadDetail(for: number) }
        }
    }

    // MARK: - List

    private var listControls: some View {
        VStack(spacing: FlotillaSpacing.small) {
            HStack(spacing: FlotillaSpacing.small) {
                TextField("Search open issues", text: $viewModel.query)
                    .textFieldStyle(.roundedBorder)
                    .accessibilityIdentifier("ProjectIssues.Search")
                Button {
                    Task { await viewModel.load() }
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.plain)
                .foregroundStyle(FlotillaColors.textSecondary)
                .disabled(viewModel.isLoading)
                .help("Refresh issues")
            }
            Picker("Show", selection: $viewModel.filter) {
                ForEach(ProjectIssueFilter.allCases) { filter in
                    Text(filter.title).tag(filter)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .accessibilityIdentifier("ProjectIssues.Filter")
        }
        .padding(FlotillaSpacing.medium)
    }

    @ViewBuilder
    private var list: some View {
        let visible = viewModel.visibleIssues(sessions: projectSessions)
        if let error = viewModel.errorMessage {
            unavailable("Couldn’t Load Issues", error, systemImage: "exclamationmark.triangle")
        } else if !viewModel.hasLoaded {
            ProgressView().controlSize(.small).frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if visible.isEmpty {
            unavailable(
                viewModel.query.isEmpty && viewModel.filter == .all ? "No Open Issues" : "No Matching Issues",
                viewModel.query.isEmpty && viewModel.filter == .all ? "This repository has no open issues." : "Try another search or filter.",
                systemImage: "number"
            )
        } else {
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(visible) { issue in
                        IssueListRow(
                            issue: issue,
                            sessions: ProjectIssuesViewModel.sessions(for: issue.number, in: projectSessions),
                            ciState: { store.ciStatusStore.status(for: $0)?.state },
                            isSelected: viewModel.selectedNumber == issue.number
                        )
                        .onTapGesture { viewModel.selectedNumber = issue.number }
                        Divider().opacity(0.35)
                    }
                }
            }
            .accessibilityIdentifier("ProjectIssues.List")
        }
    }

    // MARK: - Detail

    private func detail(_ issue: GhIssue) -> some View {
        let sessions = ProjectIssuesViewModel.sessions(for: issue.number, in: projectSessions)
        return ScrollView {
            VStack(alignment: .leading, spacing: FlotillaSpacing.large) {
                VStack(alignment: .leading, spacing: FlotillaSpacing.small) {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text("#\(issue.number)")
                            .font(FlotillaTypography.headline.monospacedDigit())
                            .foregroundStyle(FlotillaColors.textTertiary)
                        Text(issue.title)
                            .font(FlotillaTypography.headline)
                            .foregroundStyle(FlotillaColors.textPrimary)
                            .textSelection(.enabled)
                    }
                    HStack(spacing: 6) {
                        ForEach(issue.labels, id: \.self) { IssueLabelPill(label: $0) }
                        if let updated = issue.updatedAt {
                            Text("Updated \(updated.formatted(.relative(presentation: .named)))")
                                .font(FlotillaTypography.caption2)
                                .foregroundStyle(FlotillaColors.textTertiary)
                        }
                    }
                }

                HStack(spacing: FlotillaSpacing.small) {
                    Button {
                        navigator.presentedSheet = .createSession(projectID: project.id, issueNumber: issue.number)
                    } label: {
                        Label(sessions.isEmpty ? "Start Session" : "Start Another Session", systemImage: "play.fill")
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(FlotillaColors.accent)
                    .accessibilityIdentifier("ProjectIssues.StartSession")
                    Button {
                        openURL(issue.url)
                    } label: {
                        Label("Open on GitHub", systemImage: "arrow.up.right.square")
                    }
                    .buttonStyle(.bordered)
                }

                if !sessions.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(sessions.count == 1 ? "Session" : "Sessions")
                            .font(FlotillaTypography.caption.weight(.semibold))
                            .foregroundStyle(FlotillaColors.textSecondary)
                        ForEach(sessions) { session in
                            IssueSessionRow(session: session, ciState: store.ciStatusStore.status(for: session.id)?.state) {
                                openSession(session.id)
                            }
                        }
                    }
                }

                Divider()

                if let full = viewModel.details[issue.number] {
                    let body = full.body.trimmingCharacters(in: .whitespacesAndNewlines)
                    if body.isEmpty {
                        Text("No description provided.")
                            .font(FlotillaTypography.callout)
                            .foregroundStyle(FlotillaColors.textTertiary)
                    } else {
                        MarkdownView(markdown: body)
                    }
                } else if let error = viewModel.detailError {
                    Label(error, systemImage: "exclamationmark.triangle")
                        .font(FlotillaTypography.caption)
                        .foregroundStyle(FlotillaColors.danger)
                } else {
                    ProgressView().controlSize(.small)
                }
            }
            .frame(maxWidth: 760, alignment: .leading)
            .padding(FlotillaSpacing.xLarge)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .accessibilityIdentifier("ProjectIssues.Detail")
    }

    private func unavailable(_ title: String, _ message: String, systemImage: String) -> some View {
        ContentUnavailableView(title, systemImage: systemImage, description: Text(message))
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// One issue in the list, with the agent already on it, if any.
private struct IssueListRow: View {
    let issue: GhIssue
    let sessions: [Session]
    let ciState: (UUID) -> CICheckState?
    let isSelected: Bool

    var body: some View {
        HStack(alignment: .top, spacing: FlotillaSpacing.small) {
            Text("#\(issue.number)")
                .font(FlotillaTypography.caption.weight(.semibold).monospacedDigit())
                .foregroundStyle(FlotillaColors.textTertiary)
                .frame(minWidth: 40, alignment: .trailing)
            VStack(alignment: .leading, spacing: 4) {
                Text(issue.title)
                    .font(FlotillaTypography.callout.weight(.medium))
                    .foregroundStyle(FlotillaColors.textPrimary)
                    .lineLimit(2)
                HStack(spacing: 4) {
                    ForEach(issue.labels.prefix(3), id: \.self) { IssueLabelPill(label: $0) }
                    if let updated = issue.updatedAt {
                        Text(updated, format: .relative(presentation: .named))
                            .font(FlotillaTypography.caption2)
                            .foregroundStyle(FlotillaColors.textTertiary)
                    }
                }
            }
            Spacer(minLength: 4)
            if let session = sessions.first {
                HStack(spacing: 4) {
                    ProviderLogo(agent: session.agent).frame(width: 12, height: 12)
                    StatusBadge(session.status, waitingReason: session.waitingReason, variant: .compact)
                    CIStatusGlyph(state: ciState(session.id), quiet: true)
                    if sessions.count > 1 {
                        Text("+\(sessions.count - 1)")
                            .font(FlotillaTypography.caption2)
                            .foregroundStyle(FlotillaColors.textTertiary)
                    }
                }
                .help(sessions.count == 1 ? "Session: \(session.title)" : "\(sessions.count) sessions")
            }
        }
        .padding(.horizontal, FlotillaSpacing.medium)
        .padding(.vertical, 9)
        .background(isSelected ? FlotillaColors.accent.opacity(0.14) : .clear)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
        .accessibilityIdentifier("ProjectIssues.Row-\(issue.number)")
    }
}

/// A session working on the selected issue; clicking opens it.
private struct IssueSessionRow: View {
    let session: Session
    let ciState: CICheckState?
    let open: () -> Void

    var body: some View {
        Button(action: open) {
            HStack(spacing: 8) {
                ProviderLogo(agent: session.agent).frame(width: 14, height: 14)
                Text(session.title)
                    .font(FlotillaTypography.callout)
                    .foregroundStyle(FlotillaColors.textPrimary)
                    .lineLimit(1)
                StatusBadge(session.status, waitingReason: session.waitingReason, variant: .inline)
                CIStatusGlyph(state: ciState)
                Spacer(minLength: 4)
                Image(systemName: "arrow.right")
                    .foregroundStyle(FlotillaColors.textTertiary)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(FlotillaColors.surfaceElevated.opacity(0.6), in: RoundedRectangle(cornerRadius: FlotillaRadius.control, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Open \(session.title)")
    }
}

private struct IssueLabelPill: View {
    let label: String

    var body: some View {
        Text(label)
            .font(FlotillaTypography.caption3.weight(.medium))
            .foregroundStyle(FlotillaColors.textSecondary)
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .background(FlotillaColors.textTertiary.opacity(0.15), in: Capsule())
    }
}

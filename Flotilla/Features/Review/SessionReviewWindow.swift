import SwiftUI
import GitKit
import SessionKit
import DesignSystem

/// The review surface: a window per session, opened while that session is
/// Ready for Review.
///
/// Its own window rather than a panel in the shell because reviewing is a
/// whole-screen activity — a file list, a two-column diff, and comment threads
/// do not fit beside a terminal — and because a review outlives navigating the
/// fleet: you can keep reading a diff while the rest of the app moves on.
struct SessionReviewWindow: View {
    static let sceneID = "session-review"

    let sessionID: UUID
    @Bindable var store: AppStore
    let gitService: any GitServiceProtocol
    let repository: any SessionRepository

    @State private var viewModel: SessionReviewViewModel?
    @State private var draft: ReviewCommentDraft?
    @State private var draftText = ""
    @State private var isPresentingSend = false
    @State private var branch: String?
    @State private var sendResult: String?

    private var session: Session? {
        store.sessions.first { $0.id == sessionID }
    }

    var body: some View {
        Group {
            if let session, let viewModel {
                content(session: session, viewModel: viewModel)
            } else {
                missingSession
            }
        }
        .frame(minWidth: 1_000, minHeight: 560)
        .flotillaLiquidSurface(FlotillaColors.canvas, glassTintOpacity: FlotillaGlassTint.detail)
        .accessibilityIdentifier(AXID.reviewWindow.rawValue)
        .task(id: sessionID) {
            guard viewModel == nil, let session else { return }
            let model = SessionReviewViewModel(
                session: session,
                gitService: gitService,
                repository: repository
            )
            viewModel = model
            branch = try? await gitService.currentBranch(at: model.repoPath)
            await model.load()
            if self.session?.status != .readyForReview {
                model.markStale()
            }
        }
        // The window is entered from Ready for Review, but the agent can
        // resume behind it. Nothing reloads on its own — the reader is told,
        // and chooses when.
        .onChange(of: session?.status) { _, newValue in
            if newValue != .readyForReview { viewModel?.markStale() }
        }
    }

    // MARK: - Content

    private func content(session: Session, viewModel: SessionReviewViewModel) -> some View {
        VStack(spacing: 0) {
            ReviewHeaderBar(
                viewModel: viewModel,
                branch: branch,
                onRefresh: { Task { await viewModel.load() } },
                onSend: { isPresentingSend = true }
            )
            Divider()

            banners(viewModel: viewModel)

            HStack(spacing: 0) {
                ReviewFileList(viewModel: viewModel)
                Divider()
                ReviewDiffPane(viewModel: viewModel, draft: $draft, draftText: $draftText)
            }
        }
        .sheet(isPresented: $isPresentingSend) {
            ReviewSendSheet(
                reviewedSession: session,
                candidates: sendCandidates(for: session),
                prompt: prompt(for: session, viewModel: viewModel),
                commentCount: viewModel.unsentComments.count,
                onSend: { target in
                    send(to: target, session: session, viewModel: viewModel)
                },
                onSendToNewAgent: { agent in
                    sendToNewAgent(agent: agent, session: session, viewModel: viewModel)
                },
                onCancel: { isPresentingSend = false }
            )
        }
    }

    @ViewBuilder
    private func banners(viewModel: SessionReviewViewModel) -> some View {
        if viewModel.isStale {
            banner(
                "The agent resumed work — this diff may be stale.",
                systemImage: "exclamationmark.triangle",
                tint: FlotillaColors.warning
            ) {
                Button("Refresh") { Task { await viewModel.load() } }
                    .font(FlotillaTypography.caption2)
            }
            .accessibilityIdentifier(AXID.reviewStaleBanner.rawValue)
            Divider()
        }

        if let errorMessage = viewModel.errorMessage {
            banner(errorMessage, systemImage: "exclamationmark.octagon", tint: FlotillaColors.danger) {
                EmptyView()
            }
            Divider()
        }

        if let sendResult {
            banner(sendResult, systemImage: "paperplane", tint: FlotillaColors.statusReady) {
                Button("Dismiss") { self.sendResult = nil }
                    .font(FlotillaTypography.caption2)
            }
            Divider()
        }
    }

    private var missingSession: some View {
        VStack(spacing: FlotillaSpacing.small) {
            Image(systemName: "questionmark.folder")
                .font(.system(size: FlotillaIconSize.xLarge))
                .foregroundStyle(FlotillaColors.textTertiary)
            Text("This session is no longer available.")
                .font(FlotillaTypography.callout)
                .foregroundStyle(FlotillaColors.textSecondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func banner(
        _ message: String,
        systemImage: String,
        tint: Color,
        @ViewBuilder trailing: () -> some View
    ) -> some View {
        HStack(spacing: FlotillaSpacing.small) {
            Image(systemName: systemImage)
                .font(.system(size: FlotillaIconSize.xSmall))
                .foregroundStyle(tint)
            Text(message)
                .font(FlotillaTypography.caption)
                .foregroundStyle(FlotillaColors.textSecondary)
            Spacer(minLength: 0)
            trailing()
        }
        .padding(.horizontal, FlotillaSpacing.medium)
        .padding(.vertical, FlotillaSpacing.small)
        .background(tint.opacity(0.08))
    }

    // MARK: - Sending

    /// Every session that could receive the review: the reviewed one first,
    /// since its agent still holds the conversation that produced the code.
    private func sendCandidates(for session: Session) -> [Session] {
        let others = store.sessions
            .filter { $0.id != session.id && store.process(for: $0.id) != nil }
            .sorted { $0.lastActiveAt > $1.lastActiveAt }
        return store.process(for: session.id) != nil ? [session] + others : others
    }

    private func prompt(for session: Session, viewModel: SessionReviewViewModel) -> String {
        ReviewPromptFormatter.prompt(
            sessionTitle: session.title,
            branch: branch,
            comments: viewModel.unsentComments,
            files: viewModel.files
        )
    }

    private func send(
        to target: Session,
        session: Session,
        viewModel: SessionReviewViewModel
    ) {
        let delivered = viewModel.unsentComments
        guard !delivered.isEmpty else { return }
        let text = prompt(for: session, viewModel: viewModel)
        isPresentingSend = false

        Task {
            do {
                try await store.deliverMessage(text, to: target.id)
            } catch {
                sendResult = "The review could not be sent to \(target.title): \(error.localizedDescription)"
                return
            }

            do {
                try viewModel.markSent(delivered)
                sendResult = "Sent \(delivered.count) comment\(delivered.count == 1 ? "" : "s") to \(target.title)."
            } catch {
                sendResult = "The review was delivered, but its sent state could not be saved: \(error.localizedDescription)"
            }
        }
    }

    /// Spins up a brand-new session — the chosen agent, in the reviewed
    /// session's checkout — with the review as its opening task, for when no
    /// running session should pick this up or a fresh context is wanted.
    ///
    /// Model and effort carry over only when the agent is the same, since
    /// those identifiers are agent-specific; a different agent starts on its
    /// own defaults.
    private func sendToNewAgent(agent: AgentKind, session: Session, viewModel: SessionReviewViewModel) {
        let delivered = viewModel.unsentComments
        guard !delivered.isEmpty else { return }
        let text = prompt(for: session, viewModel: viewModel)
        let sameAgent = agent == session.agent
        isPresentingSend = false

        Task {
            let created = await store.createSession(
                title: "Review — \(session.title)",
                goal: text,
                agent: agent,
                model: sameAgent ? session.model : nil,
                effort: sameAgent ? session.effort : nil,
                projectFolder: session.worktree?.worktreePath ?? session.workingDirectory,
                checkoutMode: .mainCheckout,
                deliverGoal: true,
                selectAfterCreating: true
            )

            guard created != nil else {
                sendResult = "A new agent could not be started: \(store.lastCreationError ?? "unknown error")."
                return
            }

            do {
                try viewModel.markSent(delivered)
                sendResult = "Started a new \(agent.displayName) agent with \(delivered.count) comment\(delivered.count == 1 ? "" : "s")."
            } catch {
                sendResult = "The new agent was started, but the sent state could not be saved: \(error.localizedDescription)"
            }
        }
    }
}

/// The review's control strip: what you are reviewing on the left, how it is
/// shown and what to do with it on the right, and — along the bottom edge —
/// how far through the files you are.
struct ReviewHeaderBar: View {
    @Bindable var viewModel: SessionReviewViewModel
    let branch: String?
    let onRefresh: () -> Void
    let onSend: () -> Void

    var body: some View {
        HStack(spacing: FlotillaSpacing.medium) {
            identity
            Spacer(minLength: FlotillaSpacing.small)
            scopeTrack
            displayTrack
            wrapTrack
            refreshButton
            sendButton
        }
        .padding(.horizontal, FlotillaSpacing.large)
        .padding(.vertical, FlotillaSpacing.small)
        .flotillaLiquidSurface(FlotillaColors.sidebar, glassTintOpacity: FlotillaGlassTint.sidebar)
        .overlay(alignment: .bottom) {
            if viewModel.files.count > 0 {
                ReviewViewedProgressBar(viewed: viewModel.viewedCount, total: viewModel.files.count)
                    .frame(height: 2)
            }
        }
    }

    // MARK: - Identity

    private var identity: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(viewModel.session.title)
                .font(FlotillaTypography.headline)
                .foregroundStyle(FlotillaColors.textPrimary)
                .lineLimit(1)

            if let branch {
                HStack(spacing: FlotillaSpacing.xSmall) {
                    Image(systemName: "arrow.triangle.branch")
                        .font(.system(size: 9, weight: .semibold))
                    Text(BranchNaming.displayName(for: branch))
                        .font(FlotillaTypography.caption2.monospaced())
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                .foregroundStyle(FlotillaColors.textSecondary)
                .padding(.horizontal, FlotillaSpacing.small)
                .padding(.vertical, 2)
                .background(FlotillaColors.surface, in: Capsule())
                .overlay {
                    Capsule().strokeBorder(FlotillaColors.separator, lineWidth: FlotillaBorderWidth.hairline)
                }
            }
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    // MARK: - Tracks

    /// Which changes to show — branch work or just the working tree.
    private var scopeTrack: some View {
        segmentedTrack([
            ReviewScope.allCases.map { scope in
                SegmentSpec(
                    title: scope.displayName,
                    systemImage: scope == .branch ? "arrow.triangle.branch" : "pencil.line",
                    identifier: scope == .branch
                        ? AXID.reviewScopeBranch.rawValue
                        : AXID.reviewScopeUncommitted.rawValue,
                    isSelected: viewModel.scope == scope,
                    action: { Task { await viewModel.setScope(scope) } }
                )
            }
        ])
    }

    /// How the diff is shown: layout (inline / side by side) and how many
    /// files at once — two related choices in one track, split by a rule.
    private var displayTrack: some View {
        segmentedTrack([
            ReviewDiffMode.allCases.map { mode in
                SegmentSpec(
                    title: mode.title,
                    systemImage: mode.systemImage,
                    identifier: mode == .sideBySide
                        ? AXID.reviewModeSideBySide.rawValue
                        : AXID.reviewModeInline.rawValue,
                    isSelected: viewModel.diffMode == mode,
                    action: { viewModel.diffMode = mode }
                )
            },
            ReviewFileDisplay.allCases.map { display in
                SegmentSpec(
                    title: display.title,
                    systemImage: display.systemImage,
                    identifier: display == .allFiles
                        ? AXID.reviewDisplayAllFiles.rawValue
                        : AXID.reviewDisplaySingleFile.rawValue,
                    isSelected: viewModel.fileDisplay == display,
                    action: { viewModel.fileDisplay = display }
                )
            }
        ])
    }

    /// A one-segment inset toggle: raised means long lines wrap to the pane,
    /// flat means they stay on one row and the diff scrolls sideways.
    private var wrapTrack: some View {
        segmentedTrack([[
            SegmentSpec(
                title: "Wrap",
                systemImage: "arrow.turn.down.left",
                identifier: AXID.reviewWrapLines.rawValue,
                isSelected: viewModel.wrapLines,
                action: { viewModel.wrapLines.toggle() }
            )
        ]])
    }

    private var refreshButton: some View {
        Button(action: onRefresh) {
            Image(systemName: "arrow.clockwise")
                .font(.system(size: FlotillaIconSize.small, weight: .semibold))
        }
        .buttonStyle(.plain)
        .foregroundStyle(FlotillaColors.textSecondary)
        .disabled(viewModel.isLoading)
        .help("Reload the diff")
        .accessibilityLabel("Refresh")
        .accessibilityIdentifier(AXID.reviewRefresh.rawValue)
    }

    private var sendButton: some View {
        Button(action: onSend) {
            HStack(spacing: FlotillaSpacing.xSmall) {
                Image(systemName: "paperplane.fill")
                    .font(.system(size: FlotillaIconSize.xSmall))
                Text("Send Review")
                if !viewModel.unsentComments.isEmpty {
                    Text("\(viewModel.unsentComments.count)")
                        .font(FlotillaTypography.caption3.weight(.bold))
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(FlotillaColors.accentContent.opacity(0.25), in: Capsule())
                }
            }
            .font(FlotillaTypography.caption.weight(.medium))
        }
        .buttonStyle(.borderedProminent)
        .tint(FlotillaColors.accent)
        .disabled(!viewModel.canSend)
        .help(viewModel.canSend ? "Send comments to an agent" : "No unsent comments")
        .accessibilityIdentifier(AXID.reviewSend.rawValue)
    }

    // MARK: - Segmented control

    private struct SegmentSpec: Identifiable {
        let title: String
        let systemImage: String?
        let identifier: String
        let isSelected: Bool
        let action: () -> Void

        var id: String { identifier }
    }

    /// One inset track that may hold several groups of segments, each group
    /// separated from the next by a hairline rule.
    private func segmentedTrack(_ groups: [[SegmentSpec]]) -> some View {
        HStack(spacing: 2) {
            ForEach(Array(groups.enumerated()), id: \.offset) { index, group in
                if index > 0 {
                    Rectangle()
                        .fill(FlotillaColors.separator)
                        .frame(width: FlotillaBorderWidth.hairline, height: 16)
                        .padding(.horizontal, 2)
                }
                ForEach(group) { segment in
                    segmentButton(segment)
                }
            }
        }
        .padding(2)
        .background(
            FlotillaColors.canvas,
            in: RoundedRectangle(cornerRadius: FlotillaRadius.control + 2, style: .continuous)
        )
        .overlay {
            RoundedRectangle(cornerRadius: FlotillaRadius.control + 2, style: .continuous)
                .strokeBorder(FlotillaColors.separator, lineWidth: FlotillaBorderWidth.hairline)
        }
    }

    private func segmentButton(_ segment: SegmentSpec) -> some View {
        let isSelected = segment.isSelected
        return Button(action: segment.action) {
            HStack(spacing: FlotillaSpacing.xSmall) {
                if let systemImage = segment.systemImage {
                    Image(systemName: systemImage)
                        .font(.system(size: FlotillaIconSize.xSmall))
                }
                Text(segment.title)
                    .font(FlotillaTypography.caption2.weight(isSelected ? .semibold : .regular))
            }
            .foregroundStyle(isSelected ? FlotillaColors.textPrimary : FlotillaColors.textTertiary)
            .padding(.horizontal, FlotillaSpacing.small)
            .padding(.vertical, 5)
            .background {
                if isSelected {
                    RoundedRectangle(cornerRadius: FlotillaRadius.control, style: .continuous)
                        .fill(FlotillaColors.surface)
                        .shadow(color: .black.opacity(0.25), radius: 1, x: 0, y: 1)
                }
            }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
        .accessibilityIdentifier(segment.identifier)
    }
}

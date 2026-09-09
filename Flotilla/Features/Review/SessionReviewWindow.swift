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
        .frame(minWidth: 900, minHeight: 560)
        .background(FlotillaColors.canvas)
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
                onSend: { destination in
                    send(destination, session: session, viewModel: viewModel)
                },
                onCancel: { isPresentingSend = false }
            )
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
        _ destination: ReviewDestination,
        session: Session,
        viewModel: SessionReviewViewModel
    ) {
        let delivered = viewModel.unsentComments
        guard !delivered.isEmpty else { return }
        let text = prompt(for: session, viewModel: viewModel)
        isPresentingSend = false

        switch destination {
        case let .runningSession(target):
            guard store.deliverMessage(text, to: target.id) else {
                sendResult = "\(target.title) has no running agent to send to."
                return
            }
            viewModel.markSent(delivered)
            sendResult = "Sent \(delivered.count) comment\(delivered.count == 1 ? "" : "s") to \(target.title)."

        case let .newSession(agent):
            // The same checkout, not a new worktree: review feedback applies
            // to the code that was just reviewed, so branching away from it
            // would be the wrong place to act on it.
            Task {
                let created = await store.createSession(
                    title: "Review: \(session.title)",
                    goal: text,
                    agent: agent,
                    projectFolder: viewModel.repoPath,
                    checkoutMode: .mainCheckout,
                    deliverGoal: true,
                    selectAfterCreating: false
                )
                guard created != nil else {
                    sendResult = store.lastCreationError ?? "The new session could not be started."
                    return
                }
                viewModel.markSent(delivered)
                sendResult = "Started a \(agent.displayName) session with \(delivered.count) comment\(delivered.count == 1 ? "" : "s")."
            }
        }
    }
}

/// The review's control strip.
struct ReviewHeaderBar: View {
    @Bindable var viewModel: SessionReviewViewModel
    let branch: String?
    let onRefresh: () -> Void
    let onSend: () -> Void

    var body: some View {
        HStack(spacing: FlotillaSpacing.medium) {
            identity
            Spacer(minLength: FlotillaSpacing.small)
            scopePicker
            modePicker
            displayPicker
            refreshButton
            sendButton
        }
        .padding(.horizontal, FlotillaSpacing.medium)
        .padding(.vertical, FlotillaSpacing.small)
        .background(FlotillaColors.sidebar)
    }

    private var identity: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(viewModel.session.title)
                .font(FlotillaTypography.callout.weight(.semibold))
                .foregroundStyle(FlotillaColors.textPrimary)
                .lineLimit(1)
            if let branch {
                Text(branch)
                    .font(FlotillaTypography.caption2.monospaced())
                    .foregroundStyle(FlotillaColors.textTertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    private var scopePicker: some View {
        segmented(ReviewScope.allCases.map { scope in
            SegmentSpec(
                title: scope.displayName,
                systemImage: nil,
                identifier: scope == .branch
                    ? AXID.reviewScopeBranch.rawValue
                    : AXID.reviewScopeUncommitted.rawValue,
                isSelected: viewModel.scope == scope,
                action: { Task { await viewModel.setScope(scope) } }
            )
        })
    }

    /// The two layout buttons, as specified: one for each mode rather than a
    /// single toggle, so the current mode is legible without reading a label.
    private var modePicker: some View {
        segmented(ReviewDiffMode.allCases.map { mode in
            SegmentSpec(
                title: mode.title,
                systemImage: mode.systemImage,
                identifier: mode == .sideBySide
                    ? AXID.reviewModeSideBySide.rawValue
                    : AXID.reviewModeInline.rawValue,
                isSelected: viewModel.diffMode == mode,
                action: { viewModel.diffMode = mode }
            )
        })
    }

    private var displayPicker: some View {
        segmented(ReviewFileDisplay.allCases.map { display in
            SegmentSpec(
                title: display.title,
                systemImage: display.systemImage,
                identifier: display == .allFiles
                    ? AXID.reviewDisplayAllFiles.rawValue
                    : AXID.reviewDisplaySingleFile.rawValue,
                isSelected: viewModel.fileDisplay == display,
                action: { viewModel.fileDisplay = display }
            )
        })
    }

    private var refreshButton: some View {
        Button(action: onRefresh) {
            Image(systemName: "arrow.clockwise")
                .font(.system(size: FlotillaIconSize.xSmall, weight: .semibold))
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

    private func segmented(_ segments: [SegmentSpec]) -> some View {
        HStack(spacing: 2) {
            ForEach(segments) { segment in
                let isSelected = segment.isSelected
                Button(action: segment.action) {
                    HStack(spacing: FlotillaSpacing.xSmall) {
                        if let systemImage = segment.systemImage {
                            Image(systemName: systemImage)
                                .font(.system(size: FlotillaIconSize.xSmall))
                        }
                        Text(segment.title)
                            .font(FlotillaTypography.caption2.weight(isSelected ? .semibold : .regular))
                    }
                    .foregroundStyle(isSelected ? FlotillaColors.textPrimary : FlotillaColors.textSecondary)
                    .padding(.horizontal, FlotillaSpacing.small)
                    .padding(.vertical, 5)
                    .background(
                        isSelected ? FlotillaColors.accent.opacity(FlotillaStateOpacity.selected) : .clear,
                        in: RoundedRectangle(cornerRadius: FlotillaRadius.control, style: .continuous)
                    )
                    .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(isSelected ? [.isSelected] : [])
                .accessibilityIdentifier(segment.identifier)
            }
        }
        .padding(2)
        .background(
            FlotillaColors.surface,
            in: RoundedRectangle(cornerRadius: FlotillaRadius.control + 2, style: .continuous)
        )
    }
}

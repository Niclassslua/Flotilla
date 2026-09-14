import SwiftUI
import SessionKit
import DesignSystem
import CompanionKit

/// Transcript first; diff, commits, handoff, restart, and delete one step away.
struct SessionDetailView: View {
    let sessionID: CompanionSession.ID

    @Environment(CompanionStore.self) private var store
    @State private var isShowingHandoff = false
    @State private var isConfirmingRestart = false
    @State private var pendingDelete: CompanionSession?
    /// User overrides of a tool group's default expansion.
    @State private var expandedGroups: [String: Bool] = [:]
    @State private var containerHeight: CGFloat = 800

    var body: some View {
        if let session = store.session(sessionID), let macID = store.mac(forSession: sessionID)?.id {
            content(session: session, macID: macID)
        } else {
            ContentUnavailableView("Session Deleted", systemImage: "trash", description: Text("This session no longer exists on the Mac."))
        }
    }

    private func content(session: CompanionSession, macID: MacHost.ID) -> some View {
        let transcript = store.transcript(for: sessionID)
        let isActionable = store.isActionable(sessionID: sessionID)
        let mac = store.mac(macID)

        return ScrollViewReader { proxy in
            ScrollView {
                transcriptContent(session: session, transcript: transcript)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 12)
                Color.clear.frame(height: 1).id(Self.bottomAnchorID)
            }
            .defaultScrollAnchor(.bottom, for: .initialOffset)
            .onChange(of: transcript.events.count) { scrollToBottom(proxy) }
            .onChange(of: transcript.queuedPrompts.count) { scrollToBottom(proxy) }
            .onChange(of: transcript.streamingText) { scrollToBottom(proxy) }
        }
        .scrollDismissesKeyboard(.interactively)
        .background(FlotillaColors.canvas)
        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { containerHeight = $0 }
        .safeAreaInset(edge: .top, spacing: 0) {
            VStack(spacing: 0) {
                if let mac, !mac.isReachable { UnreachableBanner(mac: mac) }
                SessionHeader(session: session, diffStat: headerDiffStat(session))
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            ComposerSlot(
                session: session,
                transcript: transcript,
                pending: store.pendingInteractions(for: sessionID),
                isActionable: isActionable,
                maxCardHeight: containerHeight * 0.55
            )
        }
        .navigationTitle(session.title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu("Session Actions", systemImage: "ellipsis") {
                    NavigationLink(value: Route.commits(sessionID)) {
                        Label("Commits", systemImage: "clock.arrow.circlepath")
                    }
                    Button("Hand Off…", systemImage: "arrow.left.arrow.right") { isShowingHandoff = true }
                        .disabled(!isActionable || session.handoffTargets.isEmpty)
                    Button("Restart…", systemImage: "arrow.clockwise") { isConfirmingRestart = true }
                        .disabled(!isActionable)
                    Divider()
                    Button("Delete…", systemImage: "trash", role: .destructive) { pendingDelete = session }
                        .disabled(!isActionable)
                }
            }
        }
        .sheet(isPresented: $isShowingHandoff) {
            HandoffSheet(session: session, macID: macID)
        }
        .confirmationDialog("Restart “\(session.title)”?", isPresented: $isConfirmingRestart, titleVisibility: .visible) {
            Button("Restart") { Task { await store.restart(sessionID) } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The agent process is restarted and resumes this conversation.")
        }
        .sessionDeleteDialog(session: $pendingDelete)
    }

    private static let bottomAnchorID = "bottom"

    private func scrollToBottom(_ proxy: ScrollViewProxy) {
        withAnimation(.snappy) {
            proxy.scrollTo(Self.bottomAnchorID, anchor: .bottom)
        }
    }

    private func transcriptContent(session: CompanionSession, transcript: SessionTranscript) -> some View {
        let items = TranscriptLayout.items(from: transcript.events)
        let lastGroupID = items.last(where: { if case .toolGroup = $0 { true } else { false } })?.id
        let isWorking = session.status == .working
        // A group whose last tool waits on an answer is still being worked through.
        let isInProgress = isWorking || session.status == .waitingForInput

        return LazyVStack(alignment: .leading, spacing: 14) {
            if let reason = transcript.unavailableReason {
                Label(reason, systemImage: "text.bubble.badge.clock")
                    .font(.footnote)
                    .foregroundStyle(FlotillaColors.textSecondary)
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(FlotillaColors.surface, in: RoundedRectangle(cornerRadius: FlotillaRadius.card, style: .continuous))
            }
            ForEach(items) { item in
                switch item {
                case .user(_, let text):
                    UserMessageRow(text: text)
                case .assistant(_, let text):
                    AssistantMessageRow(markdown: text)
                case .toolGroup(let id, let calls):
                    // Expanded while the agent is still working through it,
                    // collapsed once done — unless the user chose otherwise.
                    let defaultExpanded = isInProgress && id == lastGroupID && items.last?.id == id
                    ToolGroupRow(
                        sessionID: sessionID,
                        calls: calls,
                        isExpanded: Binding(
                            get: { expandedGroups[id] ?? defaultExpanded },
                            set: { expandedGroups[id] = $0 }
                        )
                    )
                case .system(_, let text):
                    SystemNoteRow(text: text)
                case .image(_, let mimeType, let base64):
                    ImageRow(mimeType: mimeType, base64: base64)
                case .handoff(_, let from, let to):
                    HandoffRow(from: from, to: to)
                case .resolved(_, let text, let isPositive):
                    ResolvedInteractionRow(text: text, isPositive: isPositive)
                case .failed(_, let message):
                    TurnFailedRow(message: message)
                }
            }

            if let streaming = transcript.streamingText, !streaming.isEmpty {
                AssistantMessageRow(markdown: streaming)
                    .id("streaming")
            }
            if let tail = transcript.terminalTail {
                TerminalTailPreview(text: tail)
            }
            ForEach(transcript.queuedPrompts) { prompt in
                UserMessageRow(text: prompt.text, isQueued: true)
            }
            if isWorking || transcript.isStopping {
                WorkingIndicator(
                    inFlight: TranscriptLayout.inFlightCall(in: transcript.events),
                    retryAttempt: transcript.retryAttempt,
                    isStopping: transcript.isStopping
                )
            }
        }
        .animation(.snappy, value: transcript.events.count)
        .animation(.snappy, value: transcript.queuedPrompts.count)
    }

    private func headerDiffStat(_ session: CompanionSession) -> DiffStat? {
        guard let diff = store.diff(for: sessionID, commitHash: nil).value, !diff.isEmpty else { return session.diffStat }
        return diff.stat
    }
}

private struct SessionHeader: View {
    let session: CompanionSession
    let diffStat: DiffStat?

    var body: some View {
        HStack(spacing: 10) {
            ProviderLogo(agent: session.agent)
                .frame(width: 16, height: 16)
            HStack(spacing: 5) {
                StatusDot(status: session.status)
                Text(StatusPresentation.label(for: session.status, waitingReason: session.waitingReason))
                    .foregroundStyle(StatusPresentation.color(for: session.status))
                Text("· \(session.model)")
                    .foregroundStyle(FlotillaColors.textTertiary)
                    .lineLimit(1)
            }
            .font(.caption)

            Spacer(minLength: 8)

            if let diffStat, diffStat.hasChanges {
                NavigationLink(value: Route.diff(session.id, commitHash: nil, focusPath: nil)) {
                    HStack(spacing: 4) {
                        if diffStat.files > 0 {
                            Text("\(diffStat.files) \(diffStat.files == 1 ? "file" : "files")")
                                .foregroundStyle(FlotillaColors.textSecondary)
                        }
                        Text("+\(diffStat.additions)").foregroundStyle(FlotillaColors.diffAdded)
                        Text("−\(diffStat.deletions)").foregroundStyle(FlotillaColors.diffRemoved)
                        Image(systemName: "chevron.right")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(FlotillaColors.textTertiary)
                    }
                    .font(.caption.monospacedDigit())
                }
                .accessibilityLabel("Changes: \(diffStat.compactSummary)")
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(.bar)
    }
}

#Preview("Working") {
    NavigationStack { SessionDetailView(sessionID: MockFixtures.SessionID.offlineBanner) }
        .environment(CompanionStore(data: MockCompanionDataSource()))
        .preferredColorScheme(.dark)
}

#Preview("Permission") {
    NavigationStack { SessionDetailView(sessionID: MockFixtures.SessionID.flakyTest) }
        .environment(CompanionStore(data: MockCompanionDataSource()))
        .preferredColorScheme(.dark)
}

#Preview("Question") {
    NavigationStack { SessionDetailView(sessionID: MockFixtures.SessionID.authQuestion) }
        .environment(CompanionStore(data: MockCompanionDataSource()))
        .preferredColorScheme(.dark)
}

#Preview("Plan") {
    NavigationStack { SessionDetailView(sessionID: MockFixtures.SessionID.settingsPlan) }
        .environment(CompanionStore(data: MockCompanionDataSource()))
        .preferredColorScheme(.dark)
}

#Preview("Crashed") {
    NavigationStack { SessionDetailView(sessionID: MockFixtures.SessionID.dependencyCrash) }
        .environment(CompanionStore(data: MockCompanionDataSource()))
        .preferredColorScheme(.dark)
}

#Preview("Unreachable") {
    NavigationStack { SessionDetailView(sessionID: MockFixtures.SessionID.launchProfile) }
        .environment(CompanionStore(data: MockCompanionDataSource()))
        .preferredColorScheme(.light)
}

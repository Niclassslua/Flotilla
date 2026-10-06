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
    /// Within this many points of the bottom counts as "still reading the tail".
    private static let nearBottomThreshold: CGFloat = 80
    @State private var isNearBottom = true
    @State private var hasNewOutputWhileScrolledUp = false
    /// How many new-content events landed while scrolled up, shown on the
    /// jump pill instead of a bare arrow.
    @State private var newOutputCount = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isSearching = false
    @State private var searchQuery = ""
    @State private var currentMatchIndex = 0
    @State private var scrollProxy: ScrollViewProxy?
    @State private var visibleItemCount: Int = 40
    /// True while a finger is on the transcript or it's coasting; programmatic
    /// follow-scrolls must not fight the reader.
    @State private var isUserScrolling = false

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
        let items = TranscriptLayout.items(from: transcript.events)
        let matches = isSearching ? TranscriptSearch.matches(in: items, query: searchQuery) : []
        let inFlight = TranscriptLayout.inFlightCall(in: items)
        let visibleItems = isSearching ? items : Array(items.suffix(visibleItemCount))
        let hiddenCount = max(0, items.count - visibleItems.count)

        return ScrollViewReader { proxy in
            ScrollView {
                transcriptContent(
                    session: session,
                    transcript: transcript,
                    items: visibleItems,
                    totalItemCount: items.count,
                    hiddenCount: hiddenCount,
                    isSearching: isSearching
                )
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
                Color.clear.frame(height: 1).id(Self.bottomAnchorID)
            }
            .task { scrollProxy = proxy }
            .defaultScrollAnchor(.bottom, for: .initialOffset)
            .onScrollGeometryChange(for: Bool.self) { geometry in
                geometry.contentOffset.y + geometry.containerSize.height >= geometry.contentSize.height - Self.nearBottomThreshold
            } action: { _, isNear in
                if isNearBottom != isNear {
                    isNearBottom = isNear
                }
                if isNear {
                    if hasNewOutputWhileScrolledUp {
                        hasNewOutputWhileScrolledUp = false
                    }
                    if newOutputCount != 0 {
                        newOutputCount = 0
                    }
                }
            }
            .onScrollPhaseChange { _, phase in
                let scrolling = phase == .interacting || phase == .decelerating
                if isUserScrolling != scrolling { isUserScrolling = scrolling }
            }
            .onChange(of: transcript.events.count) { _, _ in handleNewContent(proxy) }
            .onChange(of: transcript.queuedPrompts.count) { _, _ in handleNewContent(proxy) }
            .onChange(of: transcript.streamingText) { _, _ in handleStreamingContent(proxy) }
            .onChange(of: items.count) { oldVal, newVal in
                if newVal > oldVal {
                    visibleItemCount += (newVal - oldVal)
                }
            }
            .onChange(of: isSearching) { _, searching in
                if searching {
                    visibleItemCount = items.count
                }
            }
            .overlay(alignment: .bottom) {
                Group {
                    if hasNewOutputWhileScrolledUp {
                        newOutputButton(proxy)
                    }
                }
                // Scoped to the pill so the toggle can't animate transcript layout.
                .animation(reduceMotion ? nil : .snappy, value: hasNewOutputWhileScrolledUp)
            }
        }
        .scrollDismissesKeyboard(.interactively)
        .background(FlotillaColors.canvas)
        .safeAreaInset(edge: .top, spacing: 0) {
            VStack(spacing: 0) {
                SessionHeader(
                    session: session,
                    diffStat: headerDiffStat(session),
                    modelDisplayName: store.catalog(on: macID).entry(for: session.agent).displayName(forSlug: session.model)
                )
                CurrentTurnSummaryRow(
                    latestLine: transcript.latestCompleteLine,
                    inFlight: inFlight,
                    diffStat: headerDiffStat(session)
                )
                if let mac, !mac.isReachable { UnreachableBanner(mac: mac, asOf: store.transcriptReceivedAt(sessionID)) }
                if isSearching {
                    TranscriptSearchBar(
                        query: $searchQuery,
                        matchCount: matches.count,
                        currentIndex: currentMatchIndex,
                        onNext: { advance(1, in: matches) },
                        onPrevious: { advance(-1, in: matches) },
                        onClose: { closeSearch() }
                    )
                    .background(FlotillaColors.canvas)
                }
            }
            .background(alignment: .top) { statusTintBackground(for: session.status) }
        }
        .onChange(of: searchQuery) { _, _ in
            currentMatchIndex = 0
            if let first = matches.first { jumpToMatch(first) }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            VStack(spacing: 0) {
                if session.status == .working || transcript.isStopping {
                    WorkingIndicator(
                        inFlight: inFlight,
                        retryAttempt: transcript.retryAttempt,
                        isStopping: transcript.isStopping
                    )
                }

                ComposerSlot(
                    session: session,
                    transcript: transcript,
                    pending: store.pendingInteractions(for: sessionID),
                    isActionable: isActionable,
                    maxCardHeight: containerHeight * 0.55
                )
            }
        }
        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { newHeight in
            if abs(containerHeight - newHeight) > 1 {
                containerHeight = newHeight
            }
        }
        .navigationTitle(session.title)
        .navigationBarTitleDisplayMode(.inline)
        .modifier(NavBarStatusTint(status: session.status))
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("Search Transcript", systemImage: "magnifyingglass") {
                    if isSearching { closeSearch() } else { isSearching = true }
                }
                .accessibilityIdentifier("Transcript.SearchToggle")
            }
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
        .sessionDeleteDialog(session: $pendingDelete, matching: session)
        .modifier(NeedsAttentionHaptic(status: session.status))
    }

    private static let bottomAnchorID = "bottom"

    /// New output only pulls the reader along when they're already at the
    /// tail; otherwise it's flagged for the "New output" jump instead.
    private func handleNewContent(_ proxy: ScrollViewProxy, animated: Bool = true) {
        if isNearBottom && !isUserScrolling {
            scrollToBottom(proxy, animated: animated)
        } else {
            hasNewOutputWhileScrolledUp = true
            newOutputCount += 1
        }
    }

    /// Streaming text changes once per provider delta (Codex can emit one per
    /// token), so they must not each increment the new-output count. The
    /// completed transcript event is counted separately by `handleNewContent`.
    private func handleStreamingContent(_ proxy: ScrollViewProxy) {
        if isNearBottom && !isUserScrolling {
            scrollToBottom(proxy, animated: false)
        } else {
            hasNewOutputWhileScrolledUp = true
        }
    }

    private func scrollToBottom(_ proxy: ScrollViewProxy, animated: Bool = true) {
        isNearBottom = true
        hasNewOutputWhileScrolledUp = false
        newOutputCount = 0
        if reduceMotion || !animated {
            proxy.scrollTo(Self.bottomAnchorID, anchor: .bottom)
        } else {
            withAnimation(.snappy) {
                proxy.scrollTo(Self.bottomAnchorID, anchor: .bottom)
            }
        }
    }

    private func newOutputButton(_ proxy: ScrollViewProxy) -> some View {
        Button {
            scrollToBottom(proxy)
        } label: {
            Group {
                if newOutputCount > 0 {
                    Label("\(newOutputCount) new", systemImage: "arrow.down")
                } else {
                    Label("New output", systemImage: "arrow.down")
                }
            }
            .font(.caption.weight(.semibold))
            .contentTransition(.numericText())
            .animation(reduceMotion ? nil : .bouncy, value: newOutputCount)
        }
        .buttonStyle(.glassProminent)
        .tint(FlotillaColors.accent)
        .controlSize(.small)
        .padding(.bottom, 8)
        .accessibilityIdentifier("Transcript.NewOutput")
        .transition(.move(edge: .bottom).combined(with: .opacity))
    }

    /// Advances by `delta` matches (wrapping) and scrolls to the result.
    private func advance(_ delta: Int, in matches: [TranscriptSearchMatch]) {
        guard !matches.isEmpty else { return }
        currentMatchIndex = (currentMatchIndex + delta + matches.count) % matches.count
        jumpToMatch(matches[currentMatchIndex])
    }

    /// Expands the match's tool group (if any) and scrolls it into view.
    private func jumpToMatch(_ match: TranscriptSearchMatch) {
        if let groupID = match.groupID { expandedGroups[groupID] = true }
        guard let scrollProxy else { return }
        if reduceMotion {
            scrollProxy.scrollTo(match.itemID, anchor: .center)
        } else {
            withAnimation(.snappy) { scrollProxy.scrollTo(match.itemID, anchor: .center) }
        }
    }

    /// Reveals older items without moving what the reader is looking at: the
    /// current first row is re-pinned to the top once the new rows are laid out.
    private func revealEarlier(_ count: Int, anchoredTo firstID: String?, total: Int) {
        visibleItemCount = min(total, visibleItemCount + count)
        guard let firstID, let scrollProxy else { return }
        Task { @MainActor in
            var transaction = Transaction()
            transaction.disablesAnimations = true
            withTransaction(transaction) {
                scrollProxy.scrollTo(firstID, anchor: .top)
            }
        }
    }

    private func closeSearch() {
        isSearching = false
        searchQuery = ""
        currentMatchIndex = 0
    }

    private func transcriptContent(
        session: CompanionSession,
        transcript: SessionTranscript,
        items: [TranscriptItem],
        totalItemCount: Int,
        hiddenCount: Int,
        isSearching: Bool
    ) -> some View {
        let lastGroupID = items.last(where: { if case .toolGroup = $0 { true } else { false } })?.id
        let isWorking = session.status == .working
        // A group whose last tool waits on an answer is still being worked through.
        let isInProgress = isWorking || session.status == .waitingForInput

        // Not lazy: lazily-measured rows swap estimated heights for real ones
        // above the viewport and make the scroll jump. The window caps the count.
        return VStack(alignment: .leading, spacing: 14) {
            if let reason = transcript.unavailableReason {
                Label(reason, systemImage: "text.bubble.badge.clock")
                    .font(.footnote)
                    .foregroundStyle(FlotillaColors.textSecondary)
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(FlotillaColors.surface, in: RoundedRectangle(cornerRadius: FlotillaRadius.card, style: .continuous))
            }

            if !isSearching && hiddenCount > 0 {
                HStack(spacing: 8) {
                    Button {
                        revealEarlier(50, anchoredTo: items.first?.id, total: totalItemCount)
                    } label: {
                        Label("Load earlier (\(min(50, hiddenCount)))", systemImage: "clock.arrow.circlepath")
                            .font(.caption.weight(.medium))
                    }
                    .buttonStyle(.bordered)
                    .tint(FlotillaColors.textSecondary)
                    .controlSize(.small)

                    if hiddenCount > 50 {
                        Button {
                            revealEarlier(totalItemCount, anchoredTo: items.first?.id, total: totalItemCount)
                        } label: {
                            Text("Load all (\(hiddenCount))")
                                .font(.caption.weight(.medium))
                        }
                        .buttonStyle(.bordered)
                        .tint(FlotillaColors.textTertiary)
                        .controlSize(.small)
                    }
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)
                .accessibilityIdentifier("Transcript.LoadEarlier")
            }

            ForEach(items) { item in
                switch item {
                case .user(_, let text):
                    UserMessageRow(text: text)
                        .equatable()
                case .assistant(_, let text):
                    AssistantMessageRow(markdown: text)
                        .equatable()
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
                        .equatable()
                case .image(_, let mimeType, let base64, _):
                    ImageRow(id: "\(sessionID):\(item.id)", mimeType: mimeType, base64: base64)
                case .handoff(_, let from, let to):
                    HandoffRow(from: from, to: to)
                        .equatable()
                case .resolved(_, let text, let isPositive):
                    ResolvedInteractionRow(text: text, isPositive: isPositive)
                        .equatable()
                case .failed(_, let message):
                    TurnFailedRow(message: message)
                        .equatable()
                }
            }

            if let streaming = transcript.streamingText, !streaming.isEmpty {
                AssistantMessageRow(markdown: streaming)
                    .id("streaming")
            }
            ForEach(transcript.queuedPrompts) { prompt in
                UserMessageRow(text: prompt.text, isQueued: true)
                    .equatable()
            }
        }
        .animation(.snappy, value: transcript.queuedPrompts.count)
    }

    private func headerDiffStat(_ session: CompanionSession) -> DiffStat? {
        guard let diff = store.diff(for: sessionID, commitHash: nil).value, !diff.isEmpty else { return session.diffStat }
        return diff.stat
    }

    /// A soft gradient behind the header, following `StatusPresentation.color`
    /// — amber while waiting, emerald when ready.
    @ViewBuilder
    private func statusTintBackground(for status: SessionStatus?) -> some View {
        if status == .waitingForInput || status == .readyForReview {
            LinearGradient(
                colors: [StatusPresentation.color(for: status).opacity(0.22), FlotillaColors.canvas],
                startPoint: .top,
                endPoint: .bottom
            )
            .allowsHitTesting(false)
        } else {
            FlotillaColors.canvas
        }
    }
}

/// Tints the navigation bar itself to match, since the
/// header's gradient alone leaves the system bar untouched above it.
private struct NavBarStatusTint: ViewModifier {
    let status: SessionStatus?

    func body(content: Content) -> some View {
        if status == .waitingForInput || status == .readyForReview {
            content.toolbarBackground(StatusPresentation.color(for: status).opacity(0.18), for: .navigationBar)
        } else {
            content
        }
    }
}

/// Fires on entering waiting-for-input or ready-for-review,
/// not on leaving it — a plain `HapticsOnChange` would fire both ways.
private struct NeedsAttentionHaptic: ViewModifier {
    let status: SessionStatus?

    private var needsAttention: Bool { status == .waitingForInput || status == .readyForReview }

    func body(content: Content) -> some View {
        content.sensoryFeedback(trigger: needsAttention) { wasAttention, isAttention in
            isAttention && !wasAttention ? .success : nil
        }
    }
}

private struct SessionHeader: View {
    let session: CompanionSession
    let diffStat: DiffStat?
    /// The catalog's friendly name for `session.model`, if it has one.
    let modelDisplayName: String?

    /// Formats a still-unresolved `provider/model` slug (an id the Mac's
    /// catalog didn't recognize — e.g. a user-configured OpenCode model)
    /// into something readable, rather than showing it verbatim: the
    /// provider prefix is dropped and hyphenated words are title-cased.
    private static func fallbackDisplayName(for slug: String) -> String {
        let base = slug.split(separator: "/").last.map(String.init) ?? slug
        guard base.contains("-") else { return base }
        return base
            .split(separator: "-")
            .map { $0.prefix(1).uppercased() + $0.dropFirst() }
            .joined(separator: " ")
    }

    var body: some View {
        HStack(spacing: 10) {
            ProviderLogo(agent: session.agent)
                .frame(width: 16, height: 16)
            HStack(spacing: 5) {
                StatusDot(status: session.status)
                Text(StatusPresentation.label(for: session.status, waitingReason: session.waitingReason))
                    .foregroundStyle(StatusPresentation.color(for: session.status))
                Text("· \(modelDisplayName ?? Self.fallbackDisplayName(for: session.model))")
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

/// A one-glance recap of the current turn — the agent's latest words, plus
/// what's actively running and known change counts when there's something
/// to say. A snapshot alongside `SessionHeader`, not a replacement for the
/// live `WorkingIndicator` near the composer.
private struct CurrentTurnSummaryRow: View {
    let latestLine: String?
    let inFlight: ToolCall?
    let diffStat: DiffStat?

    private var detail: String? {
        CurrentTurnSummaryFormatting.detail(inFlight: inFlight, diffStat: diffStat)
    }

    var body: some View {
        if latestLine != nil || detail != nil {
            VStack(alignment: .leading, spacing: 2) {
                if let latestLine {
                    Text(latestLine)
                        .font(.caption)
                        .foregroundStyle(FlotillaColors.textSecondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .accessibilityIdentifier("SessionDetail.TurnSummary.LatestLine")
                }
                if let detail {
                    Text(detail)
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(FlotillaColors.textTertiary)
                        .lineLimit(1)
                        .accessibilityIdentifier("SessionDetail.TurnSummary.Detail")
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 16)
            .padding(.top, 2)
            .padding(.bottom, 6)
            .background(.bar)
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("SessionDetail.TurnSummary")
        }
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

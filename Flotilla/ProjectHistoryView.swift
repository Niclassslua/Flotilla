import SwiftUI
import AppKit
import SessionKit
import GitKit
import DesignSystem

@Observable
@MainActor
final class ProjectHistoryViewModel {
    /// One page of `git log`. Large enough that most sessions never page at
    /// all, small enough that the first paint is immediate on a big repo.
    static let pageSize = 100

    let repoPath: URL
    private let gitService: any GitServiceProtocol

    private(set) var commits: [GitCommit] = []
    private(set) var unpushedSHAs: Set<String> = []
    private(set) var isLoading = false
    private(set) var isLoadingMore = false
    private(set) var hasMore = true
    private(set) var errorMessage: String?

    /// Worktree branches offered in the ref menu. Sourced from the existing
    /// `listWorktrees` rather than a new branch-listing call — in this app the
    /// interesting refs are exactly the ones sessions are working on.
    private(set) var availableRefs: [String] = []
    private(set) var remoteURL: String?
    private(set) var mainWorktreeBranch: String?

    /// The project's sessions, used to attribute commits to the agent that
    /// made them. Kept as a settable property because sessions come and go
    /// while the view is on screen.
    var sessions: [Session] = []
    private(set) var attributions: [String: CommitAttribution] = [:]

    /// Mirrors `GitPreferences.highlightUnseenCommits`. When off, no marker is
    /// read, written, or rendered.
    var highlightUnseenCommits = true {
        didSet { if oldValue != highlightUnseenCommits { recomputeNewCommits() } }
    }
    private(set) var newCommitSHAs: Set<String> = []
    /// The tip recorded the last time this project's history was opened.
    /// Captured once per view lifetime so the "new" badges don't clear out
    /// from under the user on a manual refresh.
    private var previouslySeenSHA: String?
    private var hasCapturedSeenMarker = false

    var selectedRef: String? {
        didSet { if oldValue != selectedRef { Task { await reload() } } }
    }
    var searchQuery: String = ""

    var selectedSHA: String? {
        didSet { if oldValue != selectedSHA { Task { await loadDetail() } } }
    }
    private(set) var detail: GitCommitDetail?
    private(set) var isLoadingDetail = false
    /// Keyed by SHA so arrow-keying through the list doesn't re-shell out for
    /// a commit that was already opened — history is immutable, so a cached
    /// detail can never go stale.
    private var detailCache: [String: GitCommitDetail] = [:]

    init(repoPath: URL, gitService: any GitServiceProtocol) {
        self.repoPath = repoPath
        self.gitService = gitService
    }

    // MARK: - Derived state

    var filteredCommits: [GitCommit] {
        let query = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !query.isEmpty else { return commits }
        return commits.filter { commit in
            commit.subject.lowercased().contains(query)
                || commit.authorName.lowercased().contains(query)
                || commit.authorEmail.lowercased().contains(query)
                || commit.sha.lowercased().hasPrefix(query)
                || commit.body.lowercased().contains(query)
        }
    }

    var isSearching: Bool {
        !searchQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// Commits bucketed by recency, newest bucket first. Grouping happens here
    /// rather than in the view so the section headers are testable.
    var groupedCommits: [(group: CommitDateGroup, commits: [GitCommit])] {
        var order: [CommitDateGroup] = []
        var buckets: [CommitDateGroup: [GitCommit]] = [:]
        for commit in filteredCommits {
            let group = CommitDateGroup(for: commit.authorDate)
            if buckets[group] == nil { order.append(group) }
            buckets[group, default: []].append(commit)
        }
        return order.map { ($0, buckets[$0] ?? []) }
    }

    func webURL(for commit: GitCommit) -> URL? {
        guard let remoteURL else { return nil }
        return GitService.webURL(forRemote: remoteURL, commitSHA: commit.sha)
    }

    func isUnpushed(_ commit: GitCommit) -> Bool { unpushedSHAs.contains(commit.sha) }

    /// The agent session that produced this commit, when it can be
    /// established. `nil` means a human made it — or the branch it was made
    /// on has since been merged away (see `loadAttributions`).
    func attribution(for commit: GitCommit) -> CommitAttribution? { attributions[commit.sha] }

    func isNew(_ commit: GitCommit) -> Bool { newCommitSHAs.contains(commit.sha) }

    var newCommitCount: Int { newCommitSHAs.count }

    /// The commit the "last reviewed" separator sits above — the newest one
    /// the user has already seen.
    var firstSeenSHA: String? {
        guard !newCommitSHAs.isEmpty else { return nil }
        return filteredCommits.first { !newCommitSHAs.contains($0.sha) }?.sha
    }

    /// The tip of what's being viewed — drawn as the anchored "you are here"
    /// dot. Only meaningful when unfiltered, since a search can hide the tip.
    func isTip(_ commit: GitCommit) -> Bool { commit.sha == commits.first?.sha }

    // MARK: - Loading

    /// History is immutable and changes only when an agent commits, so this
    /// deliberately has no polling loop — unlike `DiffPanelViewModel`, which
    /// watches a working tree. Fewer concurrent `git` subprocesses is also
    /// simply cheaper.
    func loadIfNeeded() async {
        guard commits.isEmpty, !isLoading else { return }
        await reload()
    }

    func reload() async {
        isLoading = true
        defer { isLoading = false }
        await loadRefsAndRemote()

        do {
            let page = try await gitService.log(
                at: repoPath, ref: selectedRef, skip: 0, maxCount: Self.pageSize
            )
            commits = page
            hasMore = page.count == Self.pageSize
            errorMessage = nil
            unpushedSHAs = (try? await gitService.unpushedSHAs(at: repoPath, ref: selectedRef)) ?? []
            captureSeenMarkerIfNeeded()
            recomputeNewCommits()
            await loadAttributions()
            // Never leave the detail pane empty when there is something to show.
            if selectedSHA == nil || !page.contains(where: { $0.sha == selectedSHA }) {
                selectedSHA = page.first?.sha
            }
        } catch {
            errorMessage = error.localizedDescription
            commits = []
            hasMore = false
        }
    }

    func loadMore() async {
        guard hasMore, !isLoadingMore, !isLoading, !isSearching else { return }
        isLoadingMore = true
        defer { isLoadingMore = false }
        do {
            let page = try await gitService.log(
                at: repoPath, ref: selectedRef, skip: commits.count, maxCount: Self.pageSize
            )
            // Guards against duplicates if history moved under us mid-page.
            let known = Set(commits.map(\.sha))
            commits.append(contentsOf: page.filter { !known.contains($0.sha) })
            hasMore = page.count == Self.pageSize
            // A newly loaded page can contain the seen marker, which turns
            // "everything is new" back into an accurate subset.
            recomputeNewCommits()
        } catch {
            errorMessage = error.localizedDescription
            hasMore = false
        }
    }

    private func loadDetail() async {
        guard let selectedSHA else {
            detail = nil
            return
        }
        if let cached = detailCache[selectedSHA] {
            detail = cached
            return
        }
        isLoadingDetail = true
        defer { isLoadingDetail = false }
        do {
            let loaded = try await gitService.commitDetail(sha: selectedSHA, at: repoPath)
            detailCache[selectedSHA] = loaded
            // The selection may have moved on while this was in flight.
            if self.selectedSHA == selectedSHA { detail = loaded }
        } catch {
            if self.selectedSHA == selectedSHA {
                detail = nil
                errorMessage = error.localizedDescription
            }
        }
    }

    private func loadRefsAndRemote() async {
        if let worktrees = try? await gitService.listWorktrees(at: repoPath) {
            availableRefs = worktrees.map(\.branch).filter { $0 != "(detached)" }
            mainWorktreeBranch = worktrees.first(where: \.isMainWorktree)?.branch
        }
        remoteURL = try? await gitService.remoteURL(at: repoPath)
    }

    /// Attributes commits to agent sessions by asking, for each session's
    /// worktree branch, which commits that branch owns exclusively.
    ///
    /// Attribution is reachability-based, which means it is lost once a branch
    /// is merged into the base — the commits become reachable from the base
    /// too, so they are no longer "the branch's own". That is an acceptable
    /// trade: the case this serves is reviewing what an agent *just* did,
    /// while its worktree is still live, and unattributed commits fall back to
    /// showing the git author exactly as before.
    func loadAttributions() async {
        var map: [String: CommitAttribution] = [:]

        // Weakest signal first, so stronger ones overwrite it.
        for commit in commits {
            guard let agent = AgentKind.inferredFromGitIdentity(
                name: commit.authorName, email: commit.authorEmail
            ) else { continue }
            map[commit.sha] = CommitAttribution(
                agent: agent, sessionID: nil, sessionTitle: nil,
                branchName: nil, source: .authorIdentity
            )
        }

        if let base = mainWorktreeBranch {
            for session in sessions {
                guard let branch = session.worktree?.branchName, branch != base else { continue }
                guard let shas = try? await gitService.commitsOnBranch(branch, notOn: base, at: repoPath) else { continue }
                let attribution = CommitAttribution(
                    agent: session.agent, sessionID: session.id, sessionTitle: session.title,
                    branchName: branch, source: .sessionBranch
                )
                for sha in shas { map[sha] = attribution }
            }
        }

        // A trailer is the only source that is exact and permanent, so it wins
        // outright — including over a branch guess that may be stale.
        for commit in commits {
            guard let raw = commit.trailers["flotilla-agent"],
                  let agent = AgentKind.fromTrailerValue(raw) else { continue }
            let sessionID = commit.trailers["flotilla-session"].flatMap(UUID.init(uuidString:))
            let session = sessionID.flatMap { id in sessions.first { $0.id == id } }
            map[commit.sha] = CommitAttribution(
                agent: agent,
                sessionID: sessionID,
                sessionTitle: session?.title,
                branchName: session?.worktree?.branchName,
                source: .trailer
            )
        }

        attributions = map
    }

    private var lastSeenDefaultsKey: String { "flotilla.history.lastSeen.\(repoPath.path)" }

    private func captureSeenMarkerIfNeeded() {
        guard highlightUnseenCommits, !hasCapturedSeenMarker else { return }
        hasCapturedSeenMarker = true
        previouslySeenSHA = UserDefaults.standard.string(forKey: lastSeenDefaultsKey)
    }

    private func recomputeNewCommits() {
        guard highlightUnseenCommits, let previouslySeenSHA, !commits.isEmpty else {
            newCommitSHAs = []
            return
        }
        if let index = commits.firstIndex(where: { $0.sha == previouslySeenSHA }) {
            newCommitSHAs = Set(commits.prefix(index).map(\.sha))
        } else {
            // The marker predates everything loaded, so all of it is unseen.
            newCommitSHAs = Set(commits.map(\.sha))
        }
    }

    /// Advances the marker to the current tip. Called when the user leaves the
    /// History view rather than on load, so badges survive the visit that is
    /// meant to show them.
    func markAllAsSeen() {
        guard highlightUnseenCommits, let tip = commits.first?.sha else { return }
        UserDefaults.standard.set(tip, forKey: lastSeenDefaultsKey)
        previouslySeenSHA = tip
        newCommitSHAs = []
    }
}

/// The agent a commit came from. Flotilla can establish this where a general
/// Git client cannot, because it knows which session owns which worktree — and
/// because it stamps its own commits.
struct CommitAttribution: Equatable {
    /// How the link was established, in descending order of certainty. The
    /// UI shows this so a guess never looks like a fact.
    enum Source: Equatable {
        /// A `Flotilla-Agent` trailer. Exact, permanent, survives merges.
        case trailer
        /// The commit is reachable only from a live session's branch.
        case sessionBranch
        /// The git author is a recognized agent identity.
        case authorIdentity

        var explanation: String {
            switch self {
            case .trailer: return "Recorded in the commit by Flotilla"
            case .sessionBranch: return "Only on this session's branch"
            case .authorIdentity: return "Committed under the agent's git identity"
            }
        }
    }

    let agent: AgentKind
    /// Absent when the originating session is gone or was never known — an
    /// identity match tells us the agent but not the session.
    let sessionID: UUID?
    let sessionTitle: String?
    let branchName: String?
    let source: Source

    /// What the row shows: the session name when known, since it says more
    /// than the agent's name alone.
    var displayName: String { sessionTitle ?? agent.displayName }
}

extension AgentKind {
    /// Recognizes agents that commit under their own git identity.
    ///
    /// Only the Anthropic identity is confirmed against real history in this
    /// repo (`Claude Code <noreply@anthropic.com>`); the rest are conservative
    /// guesses, matched on distinctive full strings rather than substrings so
    /// a human named "Claude" is never misattributed.
    static func inferredFromGitIdentity(name: String, email: String) -> AgentKind? {
        let name = name.lowercased()
        let email = email.lowercased()
        let domain = email.split(separator: "@").last.map(String.init) ?? ""

        if domain == "anthropic.com" || name == "claude code" || name == "claude" {
            return .claudeCode
        }
        if name == "codex" || name == "codex cli" || email.hasPrefix("codex@") {
            return .codexCLI
        }
        if name == "opencode" || domain == "opencode.ai" || email.hasPrefix("opencode@") {
            return .openCode
        }
        if name == "antigravity" || email.hasPrefix("antigravity@") {
            return .antigravity
        }
        return nil
    }

    /// The value Flotilla writes into a `Flotilla-Agent` trailer, and reads
    /// back out. `rawValue` is already stable and persisted, so it is the
    /// natural wire form.
    static func fromTrailerValue(_ value: String) -> AgentKind? {
        AgentKind(rawValue: value.trimmingCharacters(in: .whitespaces))
    }
}

/// Recency buckets for the timeline's section headers. `Hashable` so the view
/// model can group on it; ordering comes from traversal order, not the enum.
enum CommitDateGroup: Hashable {
    case today
    case yesterday
    case thisWeek
    case month(year: Int, month: Int)

    init(for date: Date) {
        let calendar = Calendar.current
        if calendar.isDateInToday(date) {
            self = .today
        } else if calendar.isDateInYesterday(date) {
            self = .yesterday
        } else if let weekAgo = calendar.date(byAdding: .day, value: -7, to: Date()), date > weekAgo {
            self = .thisWeek
        } else {
            let parts = calendar.dateComponents([.year, .month], from: date)
            self = .month(year: parts.year ?? 0, month: parts.month ?? 0)
        }
    }

    var title: String {
        switch self {
        case .today: return "Today"
        case .yesterday: return "Yesterday"
        case .thisWeek: return "Earlier This Week"
        case .month(let year, let month):
            var components = DateComponents()
            components.year = year
            components.month = month
            guard let date = Calendar.current.date(from: components) else { return "Earlier" }
            return date.formatted(.dateTime.month(.wide).year())
        }
    }
}

// MARK: - View

/// Full-width commit history for a project: a timeline of what already
/// happened, beside the detail of whichever commit is selected. Strictly
/// read-only — nothing here can disturb a worktree an agent is writing to.
struct ProjectHistoryView: View {
    let sessions: [Session]
    let highlightUnseenCommits: Bool
    @State private var viewModel: ProjectHistoryViewModel

    init(
        repoPath: URL,
        gitService: any GitServiceProtocol,
        sessions: [Session] = [],
        highlightUnseenCommits: Bool = true
    ) {
        self.sessions = sessions
        self.highlightUnseenCommits = highlightUnseenCommits
        _viewModel = State(wrappedValue: ProjectHistoryViewModel(repoPath: repoPath, gitService: gitService))
    }

    /// Changes only when something attribution actually depends on changes, so
    /// unrelated session churn (status ticks, activity) doesn't re-shell out.
    private var attributionSignature: String {
        sessions.map { "\($0.id)|\($0.worktree?.branchName ?? "")" }.joined(separator: ",")
    }

    var body: some View {
        VStack(spacing: 0) {
            filterBar
            Divider()
            HSplitView {
                timelineSection
                    .frame(minWidth: 380, idealWidth: 460)
                CommitDetailView(viewModel: viewModel)
                    .frame(minWidth: 420, idealWidth: 600)
            }
        }
        .background(FlotillaColors.canvas)
        .task(id: viewModel.repoPath) {
            viewModel.sessions = sessions
            viewModel.highlightUnseenCommits = highlightUnseenCommits
            await viewModel.loadIfNeeded()
        }
        .onChange(of: attributionSignature) { _, _ in
            viewModel.sessions = sessions
            Task { await viewModel.loadAttributions() }
        }
        .onChange(of: highlightUnseenCommits) { _, newValue in
            viewModel.highlightUnseenCommits = newValue
        }
        // Advancing the marker on the way out is what makes "new since last
        // visit" mean anything — doing it on load would clear the badges
        // before they could be read.
        .onDisappear { viewModel.markAllAsSeen() }
    }

    // MARK: - Filter bar

    private var filterBar: some View {
        HStack(spacing: FlotillaSpacing.medium) {
            refMenu
            searchField
            if viewModel.newCommitCount > 0 {
                unseenChip
            }
            Spacer(minLength: FlotillaSpacing.small)

            if viewModel.isLoading {
                ProgressView().controlSize(.small)
            }
            Text(commitCountLabel)
                .font(FlotillaTypography.caption2.monospacedDigit())
                .foregroundStyle(FlotillaColors.textTertiary)
                .accessibilityIdentifier("ProjectHistory.CommitCount")

            Button {
                Task { await viewModel.reload() }
            } label: {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: FlotillaIconSize.small))
            }
            .buttonStyle(.plain)
            .help("Refresh history")
            .accessibilityIdentifier("ProjectHistory.RefreshButton")
        }
        .padding(.horizontal, FlotillaSpacing.medium)
        .padding(.vertical, FlotillaSpacing.small)
        .background(FlotillaColors.surfaceElevated)
    }

    /// Doubles as the "mark everything read" affordance, so clearing the
    /// badges never requires hunting for a menu item.
    private var unseenChip: some View {
        Button {
            withAnimation(FlotillaMotion.fast.curve) { viewModel.markAllAsSeen() }
        } label: {
            HStack(spacing: 4) {
                Circle()
                    .fill(FlotillaColors.accent)
                    .frame(width: 5, height: 5)
                Text("\(viewModel.newCommitCount)\(viewModel.hasMore && viewModel.newCommitCount == viewModel.commits.count ? "+" : "") new")
                    .font(FlotillaTypography.caption2.weight(.medium).monospacedDigit())
            }
            .padding(.horizontal, 7)
            .padding(.vertical, 2.5)
            .background(FlotillaColors.accent.opacity(0.16), in: Capsule())
            .foregroundStyle(FlotillaColors.accent)
        }
        .buttonStyle(.plain)
        .help("Commits since you last opened this history — click to mark as seen")
        .accessibilityIdentifier("ProjectHistory.UnseenChip")
    }

    private var commitCountLabel: String {
        let count = viewModel.filteredCommits.count
        let suffix = viewModel.hasMore && !viewModel.isSearching ? "+" : ""
        return "\(count)\(suffix) commit\(count == 1 ? "" : "s")"
    }

    private var refMenu: some View {
        Menu {
            Button {
                viewModel.selectedRef = nil
            } label: {
                Label("Current branch (HEAD)", systemImage: viewModel.selectedRef == nil ? "checkmark" : "")
            }
            if !viewModel.availableRefs.isEmpty {
                Divider()
                ForEach(viewModel.availableRefs, id: \.self) { ref in
                    Button {
                        viewModel.selectedRef = ref
                    } label: {
                        Label(ref, systemImage: viewModel.selectedRef == ref ? "checkmark" : "")
                    }
                }
            }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "arrow.triangle.branch")
                    .font(.system(size: FlotillaIconSize.small))
                Text(viewModel.selectedRef ?? "HEAD")
                    .font(.system(size: 11, design: .monospaced))
                    .lineLimit(1)
                Image(systemName: "chevron.down")
                    .font(.system(size: 8, weight: .semibold))
            }
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(FlotillaColors.surface, in: Capsule())
            .foregroundStyle(FlotillaColors.textSecondary)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .accessibilityIdentifier("ProjectHistory.RefMenu")
    }

    private var searchField: some View {
        HStack(spacing: 5) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: FlotillaIconSize.small))
                .foregroundStyle(FlotillaColors.textTertiary)
            TextField("Search commits…", text: $viewModel.searchQuery)
                .textFieldStyle(.plain)
                .font(FlotillaTypography.caption)
                .accessibilityIdentifier("ProjectHistory.SearchField")
            if viewModel.isSearching {
                Button {
                    viewModel.searchQuery = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: FlotillaIconSize.small))
                        .foregroundStyle(FlotillaColors.textTertiary)
                }
                .buttonStyle(.plain)
                .help("Clear search")
            }
        }
        .padding(.horizontal, FlotillaSpacing.small)
        .padding(.vertical, 4)
        .background(FlotillaColors.surface, in: Capsule())
        .frame(maxWidth: 260)
    }

    // MARK: - Timeline

    private var timelineSection: some View {
        VStack(spacing: 0) {
            if let errorMessage = viewModel.errorMessage, viewModel.commits.isEmpty {
                ContentUnavailableView(
                    "Couldn't Load History",
                    systemImage: "exclamationmark.triangle",
                    description: Text(errorMessage)
                )
                .accessibilityIdentifier("ProjectHistory.Error")
            } else if viewModel.isLoading && viewModel.commits.isEmpty {
                ProgressView("Loading history…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if viewModel.commits.isEmpty {
                ContentUnavailableView(
                    "No Commits",
                    systemImage: "clock.arrow.circlepath",
                    description: Text("This repository has no commits yet.")
                )
                .accessibilityIdentifier("ProjectHistory.Empty")
            } else if viewModel.filteredCommits.isEmpty {
                noSearchResults
            } else {
                timelineList
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(FlotillaColors.surface)
    }

    private var noSearchResults: some View {
        ContentUnavailableView {
            Label("No Matching Commits", systemImage: "magnifyingglass")
        } description: {
            Text("Nothing in the \(viewModel.commits.count) loaded commits matches “\(viewModel.searchQuery)”.")
        } actions: {
            if viewModel.hasMore {
                Button("Load More History") {
                    Task { await viewModel.loadMore() }
                }
            }
        }
        .accessibilityIdentifier("ProjectHistory.NoResults")
    }

    private var timelineList: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0, pinnedViews: [.sectionHeaders]) {
                ForEach(viewModel.groupedCommits, id: \.group) { group, commits in
                    Section {
                        ForEach(commits) { commit in
                            if commit.sha == viewModel.firstSeenSHA {
                                lastReviewedSeparator
                            }
                            CommitTimelineRow(
                                commit: commit,
                                isSelected: viewModel.selectedSHA == commit.sha,
                                isUnpushed: viewModel.isUnpushed(commit),
                                isTip: viewModel.isTip(commit),
                                isNew: viewModel.isNew(commit),
                                attribution: viewModel.attribution(for: commit),
                                webURL: viewModel.webURL(for: commit)
                            )
                            .onTapGesture { viewModel.selectedSHA = commit.sha }
                        }
                    } header: {
                        sectionHeader(group.title, count: commits.count)
                    }
                }

                if viewModel.hasMore && !viewModel.isSearching {
                    loadMoreFooter
                }
            }
        }
        .scrollContentBackground(.hidden)
        .accessibilityIdentifier("ProjectHistory.List")
    }

    /// Marks where the unseen commits stop, so the boundary is readable even
    /// when a date group spans it.
    private var lastReviewedSeparator: some View {
        HStack(spacing: FlotillaSpacing.small) {
            Rectangle()
                .fill(FlotillaColors.accent.opacity(0.35))
                .frame(height: 1)
            Text("Seen before")
                .font(FlotillaTypography.caption2)
                .foregroundStyle(FlotillaColors.textTertiary)
                .fixedSize()
            Rectangle()
                .fill(FlotillaColors.separator)
                .frame(height: 1)
        }
        .padding(.horizontal, FlotillaSpacing.medium)
        .padding(.vertical, FlotillaSpacing.small)
        .accessibilityLabel("Everything below was already seen")
        .accessibilityIdentifier("ProjectHistory.SeenSeparator")
    }

    private func sectionHeader(_ title: String, count: Int) -> some View {
        HStack {
            Text(title)
                .font(FlotillaTypography.caption.weight(.semibold))
                .tracking(FlotillaTypography.Tracking.loose2)
                .textCase(.uppercase)
                .foregroundStyle(FlotillaColors.textTertiary)
            Spacer()
            Text("\(count)")
                .font(FlotillaTypography.caption2.monospacedDigit())
                .foregroundStyle(FlotillaColors.textTertiary)
        }
        .padding(.horizontal, FlotillaSpacing.medium)
        .padding(.top, FlotillaSpacing.medium)
        .padding(.bottom, FlotillaSpacing.xSmall)
        .background(FlotillaColors.surface)
    }

    private var loadMoreFooter: some View {
        HStack {
            Spacer()
            if viewModel.isLoadingMore {
                ProgressView().controlSize(.small)
                Text("Loading…")
                    .font(FlotillaTypography.caption)
                    .foregroundStyle(FlotillaColors.textTertiary)
            } else {
                Text("Load \(ProjectHistoryViewModel.pageSize) more")
                    .font(FlotillaTypography.caption)
                    .foregroundStyle(FlotillaColors.textTertiary)
            }
            Spacer()
        }
        .padding(.vertical, FlotillaSpacing.medium)
        .contentShape(.rect)
        .onTapGesture { Task { await viewModel.loadMore() } }
        // Auto-pages when the footer scrolls into view; the tap target stays
        // for anyone who reaches it before the load fires.
        .onAppear { Task { await viewModel.loadMore() } }
        .accessibilityIdentifier("ProjectHistory.LoadMore")
    }
}

// MARK: - Timeline row

/// One commit on the spine. The leading column draws a full-height hairline
/// with the dot centred on it, so abutting rows form a continuous line without
/// any `Canvas` or topology math.
struct CommitTimelineRow: View {
    let commit: GitCommit
    let isSelected: Bool
    let isUnpushed: Bool
    let isTip: Bool
    let isNew: Bool
    let attribution: CommitAttribution?
    let webURL: URL?

    @State private var isHovering = false

    private static let spineColumnWidth: CGFloat = 26

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            spine
            content
        }
        .padding(.trailing, FlotillaSpacing.medium)
        .padding(.vertical, FlotillaSpacing.small)
        .background(rowBackground)
        .overlay(alignment: .leading) {
            // Selected rows get an accent edge rather than a full border, so
            // the spine stays the dominant vertical line.
            if isSelected {
                Rectangle()
                    .fill(FlotillaColors.accent)
                    .frame(width: 2)
            }
        }
        .contentShape(.rect)
        .onHover { isHovering = $0 }
        .contextMenu { contextMenuItems }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("ProjectHistory.Row-\(commit.shortSHA)")
        .accessibilityLabel(accessibilityDescription)
    }

    private var rowBackground: Color {
        if isSelected { return FlotillaColors.surfaceElevated }
        if isHovering { return FlotillaColors.textPrimary.opacity(FlotillaStateOpacity.hover) }
        return .clear
    }

    private var spine: some View {
        ZStack(alignment: .top) {
            Rectangle()
                .fill(FlotillaColors.separator)
                .frame(width: 1)
                .frame(maxHeight: .infinity)
            dot
                // Aligns the dot with the subject's cap height rather than the
                // row's top edge.
                .padding(.top, 4)
        }
        .frame(width: Self.spineColumnWidth)
    }

    /// Shape carries the meaning as much as color does: the tip is filled and
    /// haloed, an unpushed commit is hollow, a merge is a ring. Color alone
    /// would fail the design system's accessibility rule.
    @ViewBuilder
    private var dot: some View {
        if commit.isMerge {
            Circle()
                .strokeBorder(FlotillaColors.statusReady, lineWidth: 2)
                .frame(width: 9, height: 9)
        } else if isTip {
            Circle()
                .fill(FlotillaColors.accent)
                .frame(width: 9, height: 9)
                .overlay {
                    Circle().strokeBorder(FlotillaColors.accent.opacity(0.25), lineWidth: 3)
                        .frame(width: 15, height: 15)
                }
        } else if isUnpushed {
            Circle()
                .strokeBorder(FlotillaColors.accent, lineWidth: 1.5)
                .frame(width: 8, height: 8)
        } else {
            Circle()
                .fill(FlotillaColors.textTertiary)
                .frame(width: 7, height: 7)
        }
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .firstTextBaseline, spacing: 5) {
                if commit.isMerge {
                    Image(systemName: "arrow.triangle.merge")
                        .font(.system(size: FlotillaIconSize.small))
                        .foregroundStyle(FlotillaColors.statusReady)
                }
                Text(commit.subject)
                    .font(FlotillaTypography.body)
                    .foregroundStyle(FlotillaColors.textPrimary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: FlotillaSpacing.small)
                if !commit.stat.isEmpty {
                    DiffStatBadge(stat: commit.stat)
                }
            }

            HStack(spacing: 5) {
                authorIdentity
                Text("·")
                    .font(FlotillaTypography.caption2)
                    .foregroundStyle(FlotillaColors.textTertiary)
                Text(HomeTimestamp.compact(commit.authorDate))
                    .font(FlotillaTypography.caption2.monospacedDigit())
                    .foregroundStyle(FlotillaColors.textTertiary)
                Text(commit.shortSHA)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(FlotillaColors.textTertiary)

                if isNew {
                    CommitRefChip(text: "NEW", systemImage: "sparkle", tint: FlotillaColors.accent)
                }
                if isUnpushed {
                    CommitRefChip(text: "unpushed", systemImage: "arrow.up.circle", tint: FlotillaColors.accent)
                }
                ForEach(Array(commit.refs.enumerated()), id: \.offset) { _, ref in
                    CommitRefChip(ref: ref)
                }
                Spacer(minLength: 0)
            }
        }
        .padding(.leading, FlotillaSpacing.small)
    }

    /// When Flotilla knows which agent session produced the commit, that is
    /// strictly more informative than the git author — in a single-developer
    /// repo the author is the same name on every row.
    @ViewBuilder
    private var authorIdentity: some View {
        if let attribution {
            ProviderLogo(agent: attribution.agent)
                .frame(width: 13, height: 13)
            Text(attribution.displayName)
                .font(FlotillaTypography.caption2.weight(.medium))
                .foregroundStyle(FlotillaColors.textSecondary)
                .lineLimit(1)
                .truncationMode(.tail)
                .help("\(attribution.agent.displayName) — \(attribution.source.explanation)")
        } else {
            ProjectMark(
                title: commit.authorName,
                tint: ProjectMark.tint(forKey: commit.authorEmail),
                size: 15
            )
            Text(commit.authorName)
                .font(FlotillaTypography.caption2)
                .foregroundStyle(FlotillaColors.textSecondary)
                .lineLimit(1)
        }
    }

    private var accessibilityDescription: String {
        var parts = [commit.subject]
        if let attribution {
            parts.append("by \(attribution.agent.displayName), \(attribution.source.explanation)")
        } else {
            parts.append("by \(commit.authorName)")
        }
        parts.append(HomeTimestamp.compact(commit.authorDate))
        if isNew { parts.append("new since your last visit") }
        if commit.isMerge { parts.append("merge commit") }
        if isUnpushed { parts.append("not yet pushed") }
        if isTip { parts.append("latest commit") }
        if !commit.stat.isEmpty {
            parts.append("\(commit.stat.additions) added, \(commit.stat.deletions) removed")
        }
        return parts.joined(separator: ", ")
    }

    @ViewBuilder
    private var contextMenuItems: some View {
        Button("Copy SHA") { copy(commit.sha) }
        Button("Copy Short SHA") { copy(commit.shortSHA) }
        Button("Copy Subject") { copy(commit.subject) }
        Button("Copy as “SHA — Subject”") { copy("\(commit.shortSHA) — \(commit.subject)") }
        if let webURL {
            Divider()
            Link("Open on the Web", destination: webURL)
            Button("Copy Link") { copy(webURL.absoluteString) }
        }
    }

    private func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}

/// Capsule chip for a ref decoration — branch, remote, or tag.
struct CommitRefChip: View {
    let text: String
    let systemImage: String
    let tint: Color

    init(text: String, systemImage: String, tint: Color) {
        self.text = text
        self.systemImage = systemImage
        self.tint = tint
    }

    init(ref: GitCommitRef) {
        self.text = ref.name
        switch ref.kind {
        case .head:
            self.systemImage = "location.fill"
            self.tint = FlotillaColors.accent
        case .localBranch:
            self.systemImage = "arrow.triangle.branch"
            self.tint = FlotillaColors.accent
        case .remoteBranch:
            self.systemImage = "cloud"
            self.tint = FlotillaColors.textTertiary
        case .tag:
            self.systemImage = "tag"
            self.tint = FlotillaColors.statusReady
        }
    }

    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: systemImage)
                .font(.system(size: 8, weight: .semibold))
            Text(text)
                .font(.system(size: 9, weight: .medium, design: .monospaced))
                .lineLimit(1)
        }
        .padding(.horizontal, 5)
        .padding(.vertical, 1.5)
        .background(tint.opacity(0.14), in: Capsule())
        .foregroundStyle(tint)
        .fixedSize()
    }
}

#Preview("Project History") {
    ProjectHistoryView(
        repoPath: URL(fileURLWithPath: "/tmp/preview"),
        gitService: PreviewGitService()
    )
    .frame(width: 1100, height: 640)
    .environment(\.colorScheme, .dark)
}

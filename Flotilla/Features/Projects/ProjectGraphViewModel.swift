import SwiftUI
import SessionKit
import GitKit
import DesignSystem

// MARK: - ViewModel

@Observable
@MainActor
final class ProjectGraphViewModel {
    static let windowSize = 500
    static let pageSize = 100

    let repoPath: URL
    private let gitService: any GitServiceProtocol

    private(set) var commits: [GitCommit] = []
    private(set) var rows: [GitGraphRow] = []
    private(set) var filteredRows: [GitGraphRow] = []
    private(set) var branches: [GitBranch] = []
    private(set) var availableRefs: [String] = []
    private(set) var remoteURL: String?
    private(set) var mainWorktreeBranch: String?
    private(set) var unpushedSHAs: Set<String> = []

    var sessions: [Session] = []
    private(set) var attributions: [String: CommitAttribution] = [:]

    var highlightUnseenCommits = true {
        didSet { if oldValue != highlightUnseenCommits { recomputeNewCommits() } }
    }
    private(set) var newCommitSHAs: Set<String> = []
    private var previouslySeenSHA: String?
    private var hasCapturedSeenMarker = false

    private(set) var isLoading = false
    private(set) var isLoadingMore = false
    private(set) var hasMore = false
    private(set) var errorMessage: String?

    private var colorIndexBySHA: [String: Int] = [:]

    var selectedBranchFilter: String? {
        didSet { if oldValue != selectedBranchFilter { recomputeFilteredRows() } }
    }

    var selectedRef: String? {
        get { selectedBranchFilter }
        set { selectedBranchFilter = newValue }
    }

    var searchQuery: String = "" {
        didSet { if oldValue != searchQuery { recomputeFilteredRows() } }
    }

    var selectedSHA: String? {
        didSet { if oldValue != selectedSHA { Task { await loadDetail() } } }
    }

    private(set) var detail: GitCommitDetail?
    private(set) var isLoadingDetail = false
    private var detailCache: [String: GitCommitDetail] = [:]

    init(repoPath: URL, gitService: any GitServiceProtocol) {
        self.repoPath = repoPath
        self.gitService = gitService
    }

    // MARK: Derived

    var gutterWidth: CGFloat {
        GraphMetrics.gutterWidth(laneCount: GitGraphLayout.laneCount(of: filteredRows))
    }

    var highlightedColorIndex: Int? {
        guard let selectedSHA else { return nil }
        return colorIndexBySHA[selectedSHA]
    }

    func laneColor(forBranch branch: GitBranch) -> Color? {
        colorIndexBySHA[branch.tipSHA].map(GraphPalette.lane)
    }

    var summaryLabel: String {
        let count = filteredRows.count
        let lanes = GitGraphLayout.laneCount(of: filteredRows)
        let commitWord = count == 1 ? "commit" : "commits"
        let laneWord = lanes == 1 ? "lane" : "lanes"
        return "\(count) \(commitWord) · \(lanes) \(laneWord) · \(branches.count) branches"
    }

    func neighbourSHA(of sha: String?, offset: Int) -> String? {
        guard !filteredRows.isEmpty else { return nil }
        guard let sha, let index = filteredRows.firstIndex(where: { $0.commit.sha == sha }) else {
            return filteredRows.first?.commit.sha
        }
        let target = index + offset
        guard filteredRows.indices.contains(target) else { return nil }
        return filteredRows[target].commit.sha
    }

    var isSearching: Bool {
        !searchQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var filteredCommits: [GitCommit] {
        filteredRows.map(\.commit)
    }

    var groupedRows: [(group: CommitDateGroup, rows: [GitGraphRow])] {
        var order: [CommitDateGroup] = []
        var buckets: [CommitDateGroup: [GitGraphRow]] = [:]
        for row in filteredRows {
            let group = CommitDateGroup(for: row.commit.authorDate)
            if buckets[group] == nil { order.append(group) }
            buckets[group, default: []].append(row)
        }
        return order.map { ($0, buckets[$0] ?? []) }
    }

    var groupedCommits: [(group: CommitDateGroup, commits: [GitCommit])] {
        groupedRows.map { ($0.group, $0.rows.map(\.commit)) }
    }

    func webURL(for commit: GitCommit) -> URL? {
        guard let remoteURL else { return nil }
        return GitService.webURL(forRemote: remoteURL, commitSHA: commit.sha)
    }

    func isUnpushed(_ commit: GitCommit) -> Bool { unpushedSHAs.contains(commit.sha) }

    func attribution(for commit: GitCommit) -> CommitAttribution? { attributions[commit.sha] }

    func isNew(_ commit: GitCommit) -> Bool { newCommitSHAs.contains(commit.sha) }

    var newCommitCount: Int { newCommitSHAs.count }

    var firstSeenSHA: String? {
        guard !newCommitSHAs.isEmpty else { return nil }
        return filteredRows.first { !newCommitSHAs.contains($0.commit.sha) }?.commit.sha
    }

    func isTip(_ commit: GitCommit) -> Bool { commit.sha == commits.first?.sha }

    // MARK: Loading

    func loadIfNeeded() async {
        guard commits.isEmpty, !isLoading else { return }
        await reload()
    }

    func reload() async {
        isLoading = true
        defer { isLoading = false }

        await loadRefsAndRemote()

        do {
            async let logTask = gitService.log(at: repoPath, ref: selectedBranchFilter, skip: 0, maxCount: Self.pageSize)
            async let graphTask = gitService.logGraph(at: repoPath, maxCount: Self.pageSize)
            async let branchesTask = gitService.branches(at: repoPath)
            async let unpushedTask = gitService.unpushedSHAs(at: repoPath, ref: selectedBranchFilter)
            let (page, graphPage, branchList) = try await (logTask, graphTask, branchesTask)
            let loaded = graphPage.isEmpty ? page : graphPage

            commits = loaded
            rows = GitGraphLayout.rows(for: loaded)
            colorIndexBySHA = Dictionary(
                rows.map { ($0.commit.sha, $0.colorIndex) },
                uniquingKeysWith: { first, _ in first }
            )
            branches = Self.ordered(branchList)
            unpushedSHAs = (try? await unpushedTask) ?? []
            errorMessage = nil
            hasMore = loaded.count == Self.pageSize

            captureSeenMarkerIfNeeded()
            recomputeNewCommits()
            await loadAttributions()
            recomputeFilteredRows()

            if let selected = selectedSHA, colorIndexBySHA[selected] != nil {
                // keep selection
            } else {
                selectedSHA = filteredRows.first?.commit.sha ?? rows.first?.commit.sha
            }
        } catch {
            errorMessage = error.localizedDescription
            commits = []
            rows = []
            filteredRows = []
            branches = []
            colorIndexBySHA = [:]
            hasMore = false
        }
    }

    func loadMore() async {
        guard hasMore, !isLoadingMore, !isLoading, !isSearching else { return }
        isLoadingMore = true
        defer { isLoadingMore = false }
        do {
            let page = try await gitService.log(
                at: repoPath, ref: selectedBranchFilter, skip: commits.count, maxCount: Self.pageSize
            )
            let known = Set(commits.map(\.sha))
            let newCommits = page.filter { !known.contains($0.sha) }
            commits.append(contentsOf: newCommits)
            hasMore = page.count == Self.pageSize
            rows = GitGraphLayout.rows(for: commits)
            colorIndexBySHA = Dictionary(
                rows.map { ($0.commit.sha, $0.colorIndex) },
                uniquingKeysWith: { first, _ in first }
            )
            recomputeNewCommits()
            recomputeFilteredRows()
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

    func loadAttributions() async {
        var map: [String: CommitAttribution] = [:]

        for commit in commits {
            guard let agent = AgentKind.inferredFromGitIdentity(
                name: commit.authorName, email: commit.authorEmail
            ) else { continue }
            map[commit.sha] = CommitAttribution(
                agent: agent, sessionID: nil, sessionTitle: nil,
                sessionGoal: nil,
                branchName: nil, source: .authorIdentity
            )
        }

        if let base = mainWorktreeBranch {
            for session in sessions {
                guard let branch = session.worktree?.branchName, branch != base else { continue }
                guard let shas = try? await gitService.commitsOnBranch(branch, notOn: base, at: repoPath) else { continue }
                let attribution = CommitAttribution(
                    agent: session.agent, sessionID: session.id, sessionTitle: session.title,
                    sessionGoal: session.goal,
                    branchName: branch, source: .sessionBranch
                )
                for sha in shas { map[sha] = attribution }
            }
        }

        for commit in commits {
            guard let raw = commit.trailers["flotilla-agent"],
                  let agent = AgentKind.fromTrailerValue(raw) else { continue }
            let sessionID = commit.trailers["flotilla-session"].flatMap(UUID.init(uuidString:))
            let session = sessionID.flatMap { id in sessions.first { $0.id == id } }
            map[commit.sha] = CommitAttribution(
                agent: agent,
                sessionID: sessionID,
                sessionTitle: session?.title,
                sessionGoal: session?.goal,
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
#if FLOTILLA_EPHEMERAL
        previouslySeenSHA = nil
#else
        previouslySeenSHA = UserDefaults.standard.string(forKey: lastSeenDefaultsKey)
#endif
    }

    private func recomputeNewCommits() {
        guard highlightUnseenCommits, let previouslySeenSHA, !commits.isEmpty else {
            newCommitSHAs = []
            return
        }
        if let index = commits.firstIndex(where: { $0.sha == previouslySeenSHA }) {
            newCommitSHAs = Set(commits.prefix(index).map(\.sha))
        } else {
            newCommitSHAs = Set(commits.map(\.sha))
        }
    }

    func markAllAsSeen() {
        guard highlightUnseenCommits, let tip = commits.first?.sha else { return }
#if !FLOTILLA_EPHEMERAL
        UserDefaults.standard.set(tip, forKey: lastSeenDefaultsKey)
#endif
        previouslySeenSHA = tip
        newCommitSHAs = []
    }

    // MARK: Filtering

    private func recomputeFilteredRows() {
        var candidateCommits = commits
        if let filter = selectedBranchFilter, let tip = tipSHA(forBranch: filter) {
            let byS = Dictionary(commits.map { ($0.sha, $0) }, uniquingKeysWith: { first, _ in first })
            var reachable: Set<String> = []
            var frontier = [tip]
            while let sha = frontier.popLast() {
                guard reachable.insert(sha).inserted, let commit = byS[sha] else { continue }
                frontier.append(contentsOf: commit.parents)
            }
            candidateCommits = candidateCommits.filter { reachable.contains($0.sha) }
        }

        let query = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if !query.isEmpty {
            candidateCommits = candidateCommits.filter { commit in
                commit.subject.lowercased().contains(query)
                    || commit.authorName.lowercased().contains(query)
                    || commit.authorEmail.lowercased().contains(query)
                    || commit.sha.lowercased().hasPrefix(query)
                    || commit.body.lowercased().contains(query)
            }
        }

        filteredRows = GitGraphLayout.rows(for: candidateCommits)

        if let currentSelected = selectedSHA, !filteredRows.contains(where: { $0.commit.sha == currentSelected }) {
            selectedSHA = filteredRows.first?.commit.sha
        }
    }

    private func tipSHA(forBranch name: String) -> String? {
        if let branch = branches.first(where: { $0.name == name }) { return branch.tipSHA }
        return commits.first { $0.refs.contains { $0.name == name } }?.sha
    }

    private static func ordered(_ branches: [GitBranch]) -> [GitBranch] {
        branches.sorted { lhs, rhs in
            if lhs.isCurrent != rhs.isCurrent { return lhs.isCurrent }
            if lhs.isRemote != rhs.isRemote { return !lhs.isRemote }
            return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
        }
    }
}

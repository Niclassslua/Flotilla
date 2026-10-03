import Foundation
import Observation
import SessionKit
import GitKit

@Observable
@MainActor
final class SessionGitSidebarViewModel {
    static let logPageSize = 100

    let repoPath: URL

    private let gitService: any GitServiceProtocol
    /// Environment for commits made here, attributing them to the session.
    var commitEnvironment: (@MainActor () -> [String: String])?

    var selectedTab: SessionGitSidebarTab = .changes
    var changeMode: SessionGitChangeMode = .uncommitted
    var selectedLogBranch: String?
    var commitMessage = ""

    private(set) var currentBranch: String?
    private(set) var defaultBranch: String?
    private(set) var changes: [SessionGitChangeItem] = []
    private(set) var branches: [GitBranch] = []
    private(set) var worktrees: [GitWorktree] = []
    private(set) var commits: [GitCommit] = []
    private(set) var isLoading = false
    private(set) var isLoadingMore = false
    private(set) var isCommitting = false
    private(set) var isMutatingBranch = false
    private(set) var hasMoreCommits = false
    private(set) var errorMessage: String?
    private(set) var actionErrorMessage: String?

    init(
        session: Session,
        gitService: any GitServiceProtocol,
        commitEnvironment: (@MainActor () -> [String: String])? = nil
    ) {
        repoPath = (session.worktree?.worktreePath ?? session.workingDirectory).standardizedFileURL
        self.gitService = gitService
        self.commitEnvironment = commitEnvironment
    }

    var monitorKey: String {
        "\(selectedTab.rawValue)|\(changeMode.rawValue)|\(selectedLogBranch ?? "")"
    }

    var defaultBranchLabel: String {
        guard let defaultBranch else { return "default" }
        return defaultBranch.hasPrefix("origin/")
            ? String(defaultBranch.dropFirst("origin/".count))
            : defaultBranch
    }

    var canCommit: Bool {
        changes.contains { $0.stageState == .staged || $0.stageState == .partiallyStaged }
            && !commitMessage.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !isCommitting
    }

    var selectedFileCount: Int {
        changes.filter { $0.stageState == .staged || $0.stageState == .partiallyStaged }.count
    }

    func monitorSelection() async {
        let key = monitorKey
        await refreshSelection()
        guard selectedTab == .changes else { return }

        while !Task.isCancelled {
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled, monitorKey == key else { return }
            await refreshChanges(showsSpinner: false)
        }
    }

    func refreshSelection() async {
        isLoading = true
        defer { isLoading = false }
        do {
            try await loadIdentity()
            switch selectedTab {
            case .changes:
                try await loadChanges()
            case .branches:
                try await loadBranches()
            case .log:
                try await loadLog(reset: true)
            case .checks:
                // Owned by `CIStatusStore`, which polls on its own schedule.
                break
            }
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func refreshChanges(showsSpinner: Bool = true) async {
        if showsSpinner { isLoading = true }
        defer { if showsSpinner { isLoading = false } }
        do {
            try await loadIdentity()
            try await loadChanges()
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func toggleStage(for item: SessionGitChangeItem) async {
        guard item.stageState != nil else { return }
        do {
            switch item.stageState {
            case .staged, .partiallyStaged:
                try await gitService.unstage(paths: [item.path], at: repoPath)
            case .unstaged:
                try await gitService.stage(paths: [item.path], at: repoPath)
            case nil:
                return
            }
            actionErrorMessage = nil
            try await loadChanges()
        } catch {
            actionErrorMessage = error.localizedDescription
        }
    }

    func commit() async {
        let message = commitMessage.trimmingCharacters(in: .whitespacesAndNewlines)
        guard canCommit, !message.isEmpty else { return }
        isCommitting = true
        defer { isCommitting = false }
        do {
            try await gitService.commit(message: message, at: repoPath, environment: commitEnvironment?() ?? [:])
            commitMessage = ""
            actionErrorMessage = nil
            try await loadChanges()
        } catch {
            actionErrorMessage = error.localizedDescription
        }
    }

    func showCommits(for branch: String) {
        selectedLogBranch = branch
        selectedTab = .log
    }

    func selectLogBranch(_ branch: String) {
        selectedLogBranch = branch
    }

    func loadMoreCommits() async {
        guard hasMoreCommits, !isLoadingMore, let branch = selectedLogBranch else { return }
        isLoadingMore = true
        defer { isLoadingMore = false }
        do {
            let page = try await gitService.log(
                at: repoPath,
                ref: branch,
                skip: commits.count,
                maxCount: Self.logPageSize
            )
            let known = Set(commits.map(\.sha))
            commits.append(contentsOf: page.filter { !known.contains($0.sha) })
            hasMoreCommits = page.count == Self.logPageSize
            actionErrorMessage = nil
        } catch {
            actionErrorMessage = error.localizedDescription
            hasMoreCommits = false
        }
    }

    func checkout(_ branch: String) async -> Bool {
        guard branch != currentBranch else { return true }
        guard await workingTreeIsClean() else { return false }
        isMutatingBranch = true
        defer { isMutatingBranch = false }
        do {
            try await gitService.checkout(branch: branch, at: repoPath)
            currentBranch = branch
            actionErrorMessage = nil
            try await loadBranches()
            return true
        } catch {
            actionErrorMessage = error.localizedDescription
            return false
        }
    }

    func createAndCheckoutBranch(named rawName: String) async -> String? {
        let branch = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !branch.isEmpty else { return nil }
        guard await workingTreeIsClean() else { return nil }
        isMutatingBranch = true
        defer { isMutatingBranch = false }
        do {
            try await gitService.createAndCheckoutBranch(named: branch, at: repoPath)
            currentBranch = branch
            selectedLogBranch = branch
            actionErrorMessage = nil
            try await loadBranches()
            return branch
        } catch {
            actionErrorMessage = error.localizedDescription
            return nil
        }
    }

    func isBranchMerged(_ branch: String) async -> Bool? {
        guard let defaultBranch else { return nil }
        do {
            let merged = try await gitService.isBranchMerged(branch, into: defaultBranch, at: repoPath)
            actionErrorMessage = nil
            return merged
        } catch {
            actionErrorMessage = error.localizedDescription
            return nil
        }
    }

    func deleteBranch(_ branch: String, force: Bool) async {
        isMutatingBranch = true
        defer { isMutatingBranch = false }
        do {
            try await gitService.deleteBranch(branch, force: force, at: repoPath)
            if selectedLogBranch == branch { selectedLogBranch = currentBranch }
            actionErrorMessage = nil
            try await loadBranches()
        } catch {
            actionErrorMessage = error.localizedDescription
        }
    }

    func clearActionError() {
        actionErrorMessage = nil
    }

    private func loadIdentity() async throws {
        let branch = try await gitService.currentBranch(at: repoPath)
        currentBranch = branch
        defaultBranch = (try? await gitService.defaultBranch(at: repoPath)) ?? branch
        if selectedLogBranch == nil { selectedLogBranch = branch }
    }

    private func loadChanges() async throws {
        switch changeMode {
        case .uncommitted:
            let snapshot = try await gitService.changes(at: repoPath)
            changes = Self.items(from: snapshot)
        case .versusDefault:
            guard let defaultBranch else {
                changes = []
                return
            }
            let compared = try await gitService.changesCompared(to: defaultBranch, at: repoPath)
            changes = compared
                .map(Self.item(from:))
                .sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
        }
    }

    private func loadBranches() async throws {
        async let branchRequest = gitService.branches(at: repoPath)
        async let worktreeRequest = gitService.listWorktrees(at: repoPath)
        let (allBranches, loadedWorktrees) = try await (branchRequest, worktreeRequest)
        worktrees = loadedWorktrees
        branches = allBranches
            .filter { !$0.isRemote }
            .sorted { lhs, rhs in
                let lhsIsCurrent = lhs.name == currentBranch
                let rhsIsCurrent = rhs.name == currentBranch
                if lhsIsCurrent != rhsIsCurrent { return lhsIsCurrent }
                if lhs.lastCommitDate != rhs.lastCommitDate {
                    return lhs.lastCommitDate > rhs.lastCommitDate
                }
                return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
            }
    }

    private func loadLog(reset: Bool) async throws {
        if branches.isEmpty { try await loadBranches() }
        let branch = selectedLogBranch ?? currentBranch
        guard let branch else {
            commits = []
            hasMoreCommits = false
            return
        }
        selectedLogBranch = branch
        let page = try await gitService.log(
            at: repoPath,
            ref: branch,
            skip: reset ? 0 : commits.count,
            maxCount: Self.logPageSize
        )
        if reset { commits = page } else { commits.append(contentsOf: page) }
        hasMoreCommits = page.count == Self.logPageSize
    }

    private func workingTreeIsClean() async -> Bool {
        do {
            guard try await gitService.status(at: repoPath).isClean else {
                actionErrorMessage = "Commit or discard uncommitted changes before switching branches."
                return false
            }
            return true
        } catch {
            actionErrorMessage = error.localizedDescription
            return false
        }
    }

    private static func items(from snapshot: GitChangesSnapshot) -> [SessionGitChangeItem] {
        let statusByPath = Dictionary(
            snapshot.status.entries.map { ($0.path, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        let paths = Set(snapshot.allDiffs.map(\.path))

        return paths.map { path in
            let staged = snapshot.staged.filter { $0.path == path }
            let unstaged = (snapshot.unstaged + snapshot.untracked).filter { $0.path == path }
            let stageState: SessionGitStageState
            if !staged.isEmpty, !unstaged.isEmpty {
                stageState = .partiallyStaged
            } else if !staged.isEmpty {
                stageState = .staged
            } else {
                stageState = .unstaged
            }
            let stat = (staged + unstaged).reduce(
                GitDiffStat(additions: 0, deletions: 0)
            ) { $0 + $1.stat }
            return SessionGitChangeItem(
                path: path,
                kind: kind(for: statusByPath[path]),
                stat: stat,
                stageState: stageState
            )
        }
        .sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
    }

    private static func item(from change: GitCommitFileChange) -> SessionGitChangeItem {
        let kind: SessionGitChangeKind = switch change.kind {
        case .added: .added
        case .deleted: .deleted
        case .renamed, .copied: .renamed
        case .modified, .typeChanged, .unmerged: .modified
        }

        return SessionGitChangeItem(
            path: change.path,
            kind: kind,
            stat: change.stat,
            stageState: nil
        )
    }

    private static func kind(for status: GitStatusEntry?) -> SessionGitChangeKind {
        guard let status else { return .modified }
        let markers = [status.indexStatus, status.worktreeStatus]
        if status.isUntracked || markers.contains("A") { return .added }
        if markers.contains("D") { return .deleted }
        if markers.contains("R") { return .renamed }
        return .modified
    }
}


import Foundation

/// Scriptable stand-in for `GitServiceProtocol`, used by higher-level view
/// model tests and `UI_TESTING=1` runs so they never touch a real repo.
public final class MockGitService: GitServiceProtocol, @unchecked Sendable {
    public var branchToReturn = "main"
    public var defaultBranchToReturn = "main"
    public var statusToReturn = GitStatus(entries: [])
    public var diffToReturn: [FileDiff] = []
    public var stagedDiffToReturn: [FileDiff]?
    public var unstagedDiffToReturn: [FileDiff]?
    public var diffStatToReturn = GitDiffStat(additions: 0, deletions: 0)
    public var comparisonChangesToReturn: [GitCommitFileChange] = []
    public var uncommittedChangesToReturn: [GitCommitFileChange] = []
    public var worktreesToReturn: [GitWorktree] = []
    public var logToReturn: [GitCommit] = []
    public var graphLogToReturn: [GitCommit] = []
    public var branchesToReturn: [GitBranch] = []
    /// When `nil`, `commitDetail` synthesizes a file-less detail from
    /// `logToReturn`, so tests that only care about selection don't have to
    /// script a whole detail payload.
    public var commitDetailToReturn: GitCommitDetail?
    public var unpushedSHAsToReturn: Set<String> = []
    public var remoteURLToReturn: String?
    public var hooksPathToReturn = ".git/hooks"
    /// Keyed by branch name — the SHAs that branch owns exclusively.
    public var commitsOnBranchToReturn: [String: Set<String>] = [:]
    public var mergedBranchesToReturn: Set<String> = []
    public var errorToThrow: Error?

    public private(set) var createWorktreeCalls: [(basePath: URL, branch: String, destination: URL)] = []
    public private(set) var removeWorktreeCalls: [(path: URL, repoPath: URL, branch: String, deleteBranch: Bool)] = []
    public private(set) var stageCalls: [(paths: [String], repoPath: URL)] = []
    public private(set) var unstageCalls: [(paths: [String], repoPath: URL)] = []
    public private(set) var discardCalls: [(paths: [String], repoPath: URL)] = []
    public private(set) var commitCalls: [(message: String, repoPath: URL)] = []
    public private(set) var pushCalls: [(branch: String, repoPath: URL)] = []
    public private(set) var fetchCalls: [URL] = []
    public private(set) var logCalls: [(repoPath: URL, ref: String?, skip: Int, maxCount: Int)] = []
    public private(set) var logGraphCalls: [(repoPath: URL, maxCount: Int)] = []
    public private(set) var branchesCalls: [URL] = []
    public private(set) var commitDetailCalls: [(sha: String, repoPath: URL)] = []
    public private(set) var commitsOnBranchCalls: [(branch: String, base: String, repoPath: URL)] = []
    public private(set) var comparisonCalls: [(base: String, repoPath: URL)] = []
    public private(set) var uncommittedChangeCalls: [URL] = []
    public private(set) var checkoutCalls: [(branch: String, repoPath: URL)] = []
    public private(set) var createBranchCalls: [(branch: String, repoPath: URL)] = []
    public private(set) var deleteBranchCalls: [(branch: String, force: Bool, repoPath: URL)] = []
    public private(set) var mergedBranchCalls: [(branch: String, base: String, repoPath: URL)] = []

    public init() {}

    public func currentBranch(at repoPath: URL) async throws -> String {
        if let errorToThrow { throw errorToThrow }
        return branchToReturn
    }

    public func status(at repoPath: URL) async throws -> GitStatus {
        if let errorToThrow { throw errorToThrow }
        return statusToReturn
    }

    public func diff(at repoPath: URL, staged: Bool) async throws -> [FileDiff] {
        if let errorToThrow { throw errorToThrow }
        if staged, let stagedDiffToReturn { return stagedDiffToReturn }
        if !staged, let unstagedDiffToReturn { return unstagedDiffToReturn }
        return diffToReturn
    }

    public func diffStat(at repoPath: URL) async throws -> GitDiffStat {
        if let errorToThrow { throw errorToThrow }
        return diffStatToReturn
    }

    public func listWorktrees(at repoPath: URL) async throws -> [GitWorktree] {
        if let errorToThrow { throw errorToThrow }
        return worktreesToReturn
    }

    public func createWorktree(basePath: URL, branch: String, destination: URL) async throws -> GitWorktree {
        createWorktreeCalls.append((basePath, branch, destination))
        if let errorToThrow { throw errorToThrow }
        let wt = GitWorktree(branch: branch, path: destination, isMainWorktree: false)
        if !worktreesToReturn.contains(where: { $0.path == destination }) {
            worktreesToReturn.append(wt)
        }
        return wt
    }

    public func removeWorktree(at path: URL, in repoPath: URL, branch: String, deleteBranch: Bool) async throws {
        removeWorktreeCalls.append((path, repoPath, branch, deleteBranch))
        if let errorToThrow { throw errorToThrow }
    }

    public func stage(paths: [String], at repoPath: URL) async throws {
        stageCalls.append((paths, repoPath))
        if let errorToThrow { throw errorToThrow }
    }

    public func unstage(paths: [String], at repoPath: URL) async throws {
        unstageCalls.append((paths, repoPath))
        if let errorToThrow { throw errorToThrow }
    }

    public func discard(paths: [String], at repoPath: URL) async throws {
        discardCalls.append((paths, repoPath))
        if let errorToThrow { throw errorToThrow }
    }

    public func commit(message: String, at repoPath: URL) async throws {
        commitCalls.append((message, repoPath))
        if let errorToThrow { throw errorToThrow }
    }

    public func push(branch: String, at repoPath: URL) async throws {
        pushCalls.append((branch, repoPath))
        if let errorToThrow { throw errorToThrow }
    }

    public func fetch(at repoPath: URL) async throws {
        fetchCalls.append(repoPath)
        if let errorToThrow { throw errorToThrow }
    }

    public func log(at repoPath: URL, ref: String?, skip: Int, maxCount: Int) async throws -> [GitCommit] {
        logCalls.append((repoPath, ref, skip, maxCount))
        if let errorToThrow { throw errorToThrow }
        let source = !logToReturn.isEmpty ? logToReturn : graphLogToReturn
        guard skip < source.count else { return [] }
        return Array(source[skip..<min(skip + maxCount, source.count)])
    }

    public func commitDetail(sha: String, at repoPath: URL) async throws -> GitCommitDetail {
        commitDetailCalls.append((sha, repoPath))
        if let errorToThrow { throw errorToThrow }
        if let scripted = commitDetailToReturn { return scripted }
        let source = !logToReturn.isEmpty ? logToReturn : graphLogToReturn
        guard let commit = source.first(where: { $0.sha == sha }) else {
            throw GitServiceError.commitNotFound(sha)
        }
        return GitCommitDetail(commit: commit, files: [])
    }

    public func unpushedSHAs(at repoPath: URL, ref: String?) async throws -> Set<String> {
        if let errorToThrow { throw errorToThrow }
        return unpushedSHAsToReturn
    }

    public func remoteURL(at repoPath: URL) async throws -> String? {
        if let errorToThrow { throw errorToThrow }
        return remoteURLToReturn
    }

    public var fileChurnToReturn: [String: Int] = [:]
    public func fileChurn(at repoPath: URL, since: Date) async throws -> [String: Int] {
        if let errorToThrow { throw errorToThrow }
        return fileChurnToReturn
    }

    public func currentHooksPath(at repoPath: URL) async throws -> String {
        if let errorToThrow { throw errorToThrow }
        return hooksPathToReturn
    }

    public func commitsOnBranch(_ branch: String, notOn base: String, at repoPath: URL) async throws -> Set<String> {
        commitsOnBranchCalls.append((branch, base, repoPath))
        if let errorToThrow { throw errorToThrow }
        return commitsOnBranchToReturn[branch] ?? []
    }

    public func logGraph(at repoPath: URL, maxCount: Int) async throws -> [GitCommit] {
        logGraphCalls.append((repoPath, maxCount))
        if let errorToThrow { throw errorToThrow }
        if !graphLogToReturn.isEmpty { return Array(graphLogToReturn.prefix(maxCount)) }
        return Array(logToReturn.prefix(maxCount))
    }

    public func branches(at repoPath: URL) async throws -> [GitBranch] {
        branchesCalls.append(repoPath)
        if let errorToThrow { throw errorToThrow }
        return branchesToReturn
    }

    public func defaultBranch(at repoPath: URL) async throws -> String {
        if let errorToThrow { throw errorToThrow }
        return defaultBranchToReturn
    }

    public func changesCompared(to base: String, at repoPath: URL) async throws -> [GitCommitFileChange] {
        comparisonCalls.append((base, repoPath))
        if let errorToThrow { throw errorToThrow }
        return comparisonChangesToReturn
    }

    public func uncommittedChanges(at repoPath: URL) async throws -> [GitCommitFileChange] {
        uncommittedChangeCalls.append(repoPath)
        if let errorToThrow { throw errorToThrow }
        return uncommittedChangesToReturn
    }

    public func checkout(branch: String, at repoPath: URL) async throws {
        checkoutCalls.append((branch, repoPath))
        if let errorToThrow { throw errorToThrow }
        branchToReturn = branch
    }

    public func createAndCheckoutBranch(named branch: String, at repoPath: URL) async throws {
        createBranchCalls.append((branch, repoPath))
        if let errorToThrow { throw errorToThrow }
        branchToReturn = branch
    }

    public func deleteBranch(_ branch: String, force: Bool, at repoPath: URL) async throws {
        deleteBranchCalls.append((branch, force, repoPath))
        if let errorToThrow { throw errorToThrow }
    }

    public func isBranchMerged(_ branch: String, into base: String, at repoPath: URL) async throws -> Bool {
        mergedBranchCalls.append((branch, base, repoPath))
        if let errorToThrow { throw errorToThrow }
        return mergedBranchesToReturn.contains(branch)
    }
}

/// Scriptable stand-in for `GhServiceProtocol`.
public final class MockGhService: GhServiceProtocol, @unchecked Sendable {
    public var urlToReturn = URL(string: "https://github.com/example/example/pull/1")!
    public var errorToThrow: Error?

    public private(set) var createPullRequestCalls: [(title: String, body: String, base: String?, repoPath: URL)] = []

    public init() {}

    public func createPullRequest(title: String, body: String, base: String?, at repoPath: URL) async throws -> URL {
        createPullRequestCalls.append((title, body, base, repoPath))
        if let errorToThrow { throw errorToThrow }
        return urlToReturn
    }
}

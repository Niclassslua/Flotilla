import Foundation

/// Scriptable stand-in for `GitServiceProtocol`, used by higher-level view
/// model tests and `UI_TESTING=1` runs so they never touch a real repo.
public final class MockGitService: GitServiceProtocol, @unchecked Sendable {
    public var branchToReturn = "main"
    public var statusToReturn = GitStatus(entries: [])
    public var diffToReturn: [FileDiff] = []
    public var diffStatToReturn = GitDiffStat(additions: 0, deletions: 0)
    public var worktreesToReturn: [GitWorktree] = []
    public var errorToThrow: Error?

    public private(set) var createWorktreeCalls: [(basePath: URL, branch: String, destination: URL)] = []
    public private(set) var removeWorktreeCalls: [(path: URL, repoPath: URL, branch: String, deleteBranch: Bool)] = []
    public private(set) var stageCalls: [(paths: [String], repoPath: URL)] = []
    public private(set) var unstageCalls: [(paths: [String], repoPath: URL)] = []
    public private(set) var discardCalls: [(paths: [String], repoPath: URL)] = []
    public private(set) var commitCalls: [(message: String, repoPath: URL)] = []
    public private(set) var pushCalls: [(branch: String, repoPath: URL)] = []
    public private(set) var fetchCalls: [URL] = []

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
        return GitWorktree(branch: branch, path: destination, isMainWorktree: false)
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

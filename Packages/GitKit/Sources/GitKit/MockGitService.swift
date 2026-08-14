import Foundation

/// Scriptable stand-in for `GitServiceProtocol`, used by higher-level view
/// model tests and `UI_TESTING=1` runs so they never touch a real repo.
public final class MockGitService: GitServiceProtocol, @unchecked Sendable {
    public var branchToReturn = "main"
    public var statusToReturn = GitStatus(entries: [])
    public var diffToReturn: [FileDiff] = []
    public var worktreesToReturn: [GitWorktree] = []
    public var errorToThrow: Error?

    public private(set) var createWorktreeCalls: [(basePath: URL, branch: String, destination: URL)] = []
    public private(set) var removeWorktreeCalls: [(path: URL, repoPath: URL, branch: String, deleteBranch: Bool)] = []

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
}

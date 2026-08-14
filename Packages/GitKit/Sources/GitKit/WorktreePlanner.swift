import Foundation

/// Pure decision logic for the session-creation flow's "main checkout vs.
/// new worktree" choice — no git calls, fully unit-testable.
public enum CheckoutDecision: Equatable, Sendable {
    case useExistingCheckout(path: URL)
    case createWorktree(basePath: URL, branch: String, destination: URL)
}

public struct WorktreePlanner {
    public init() {}

    public func plan(
        useNewWorktree: Bool,
        projectRoot: URL,
        worktreeBaseDirectory: URL,
        branchName: String
    ) -> CheckoutDecision {
        guard useNewWorktree else {
            return .useExistingCheckout(path: projectRoot)
        }
        let destination = worktreeBaseDirectory.appendingPathComponent(branchName, isDirectory: true)
        return .createWorktree(basePath: projectRoot, branch: branchName, destination: destination)
    }
}

import Foundation

/// PR creation via the GitHub CLI. Kept separate from `GitServiceProtocol`:
/// `gh` is a distinct binary with distinct availability (see
/// `StartupCheckViewModel`, which already detects it alongside `git` and
/// `tmux`) and distinct failure modes (auth, not a GitHub repo, no
/// upstream) that shouldn't be mixed into `GitServiceError`.
public protocol GhServiceProtocol: Sendable {
    /// Creates a pull request for the current branch and returns its URL.
    /// `base` is the target branch; `nil` lets `gh` use the repository's
    /// default branch.
    func createPullRequest(title: String, body: String, base: String?, at repoPath: URL) async throws -> URL
}

/// Real `gh` integration. Invoked by absolute path rather than relying on
/// `PATH` being inherited — `gh`'s resolved location comes from
/// `StartupEnvironmentChecker`/`PATHExecutableLocator` (the same mechanism
/// `StartupCheckViewModel` already uses to detect it), since a GUI app
/// launched from Finder may not inherit a shell's augmented `PATH`.
public struct GhService: GhServiceProtocol {
    private let runner: CommandRunning
    private let ghExecutable: URL

    public init(ghExecutable: URL, runner: CommandRunning = ProcessCommandRunner()) {
        self.ghExecutable = ghExecutable
        self.runner = runner
    }

    public func createPullRequest(title: String, body: String, base: String?, at repoPath: URL) async throws -> URL {
        var arguments = ["pr", "create", "--title", title, "--body", body, "--json", "url", "-q", ".url"]
        if let base {
            arguments += ["--base", base]
        }
        let result = try await runner.run(arguments, executable: ghExecutable, workingDirectory: repoPath)
        guard result.exitCode == 0 else {
            throw GitServiceError.prCreationFailed(exitCode: result.exitCode, stderr: result.stderr)
        }
        let trimmed = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmed) else {
            throw GitServiceError.prCreationFailed(exitCode: result.exitCode, stderr: "gh returned an unparseable URL: \(trimmed)")
        }
        return url
    }
}

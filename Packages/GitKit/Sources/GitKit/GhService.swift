import Foundation
import ProcessKit

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
    /// What CI says about `branch`: its pull request's checks when it has an
    /// open or past PR, otherwise the Actions runs for the worktree's HEAD
    /// commit (so a push of that SHA to any remote branch — including
    /// landing on `main` — still counts). `nil` when neither exists.
    func ciStatus(forBranch branch: String, at repoPath: URL) async throws -> CIStatus?
    /// The whole log of one finished Actions job, available even while the
    /// rest of its run is still going.
    func jobLog(jobID: Int, at repoPath: URL) async throws -> String
    /// The worktree's tip and how much of it GitHub has not seen. Local only.
    func localTip(at repoPath: URL) async throws -> CILocalTip?
    /// Open issues, most recently updated first, optionally narrowed by
    /// GitHub's own search syntax (`gh issue list --search`).
    func openIssues(search: String, limit: Int, at repoPath: URL) async throws -> [GhIssue]
    /// One issue including its body.
    func issue(number: Int, at repoPath: URL) async throws -> GhIssue
}

/// Real `gh` integration. Invoked by absolute path rather than relying on
/// `PATH` being inherited — `gh`'s resolved location comes from
/// `StartupEnvironmentChecker`/`PATHExecutableLocator` (the same mechanism
/// `StartupCheckViewModel` already uses to detect it), since a GUI app
/// launched from Finder may not inherit a shell's augmented `PATH`.
public struct GhService: GhServiceProtocol {
    private let runner: CommandRunning
    private let ghExecutable: URL

    public init(ghExecutable: URL, runner: CommandRunning = ProcessCommandRunner(environmentOverrides: ["GIT_TERMINAL_PROMPT": "0"])) {
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

    public func ciStatus(forBranch branch: String, at repoPath: URL) async throws -> CIStatus? {
        let pr = try await runner.run(
            ["pr", "view", branch, "--json", "number,url,state,isDraft,reviewDecision,headRefOid,mergeStateStatus,statusCheckRollup"],
            executable: ghExecutable,
            workingDirectory: repoPath
        )
        if pr.exitCode == 0 {
            var status = try GhJSON.pullRequestStatus(from: Data(pr.stdout.utf8))
            if status.pullRequest?.state == .open {
                await markRequiredChecks(&status, branch: branch, at: repoPath)
                return status
            }
            // `gh` still answers with a finished PR after the branch moves on.
            // Commits beyond it belong to no PR, so judge them on their own.
            guard let head = try await headSHA(at: repoPath), let prHead = status.pullRequest?.headSHA, head != prHead else {
                return status
            }
        } else {
            // Anything other than "this branch has no PR" — auth, network, not
            // a GitHub repository — is a real failure the caller should see.
            guard pr.stderr.localizedCaseInsensitiveContains("no pull requests found") else {
                throw GitServiceError.ghCommandFailed(exitCode: pr.exitCode, stderr: pr.stderr)
            }
        }
        // Key by commit, not branch name: landing via `git push origin HEAD:main`
        // (or any other remote ref) still leaves CI on this SHA.
        guard let headSHA = try await headSHA(at: repoPath) else { return nil }
        let runs = try await runner.run(
            ["run", "list", "--commit", headSHA, "--limit", "20", "--json", "databaseId,workflowName,status,conclusion,url,headSha,createdAt,updatedAt"],
            executable: ghExecutable,
            workingDirectory: repoPath
        )
        guard runs.exitCode == 0 else {
            throw GitServiceError.ghCommandFailed(exitCode: runs.exitCode, stderr: runs.stderr)
        }
        let checks = try GhJSON.workflowRunChecks(from: Data(runs.stdout.utf8))
        guard !checks.isEmpty else { return nil }
        return CIStatus(checks: await expandedToJobs(checks, at: repoPath), commitSHA: headSHA)
    }

    /// Marks which checks branch protection requires. Only worth a request
    /// when something failed. `gh pr checks` exits non-zero for reasons that
    /// still print a usable answer, so the output decides, not the exit code;
    /// no usable answer leaves requirement unknown, which counts as blocking.
    private func markRequiredChecks(_ status: inout CIStatus, branch: String, at repoPath: URL) async {
        guard !status.failingChecks.isEmpty,
              let result = try? await runner.run(
                ["pr", "checks", branch, "--required", "--json", "name,workflow"],
                executable: ghExecutable,
                workingDirectory: repoPath
              ),
              let required = try? GhJSON.requiredCheckIDs(from: Data(result.stdout.utf8)),
              !required.isEmpty else { return }
        for index in status.checks.indices {
            status.checks[index].isRequired = required.contains(status.checks[index].id)
        }
    }

    /// Replaces each failing or running workflow with its jobs. A settled
    /// green workflow stays one row, which saves the request. If the lookup
    /// fails the workflow row stands: less detail, still the right colour.
    private func expandedToJobs(_ checks: [CICheck], at repoPath: URL) async -> [CICheck] {
        var expanded: [CICheck] = []
        for check in checks {
            guard check.state == .failing || check.state == .pending, let runID = check.runID,
                  let result = try? await runner.run(
                    ["run", "view", String(runID), "--json", "jobs"],
                    executable: ghExecutable,
                    workingDirectory: repoPath
                  ),
                  result.exitCode == 0,
                  let jobs = try? GhJSON.jobChecks(from: Data(result.stdout.utf8), workflowName: check.workflowName, runID: runID),
                  !jobs.isEmpty else {
                expanded.append(check)
                continue
            }
            expanded += jobs
        }
        return expanded
    }

    /// Worktree tip. `/usr/bin/git` is the macOS CLT shim Flotilla already
    /// requires; keeping git off `GhService`'s initializer avoids threading a
    /// second binary through every call site for one rev-parse.
    private static let git = URL(fileURLWithPath: "/usr/bin/git")

    public func localTip(at repoPath: URL) async throws -> CILocalTip? {
        guard let sha = try await headSHA(at: repoPath) else { return nil }
        // Any remote-tracking ref counts, so `git push origin HEAD:main` does too.
        let unpushed = try await runner.run(
            ["rev-list", "--count", "HEAD", "--not", "--remotes"],
            executable: Self.git,
            workingDirectory: repoPath
        )
        guard unpushed.exitCode == 0,
              let count = Int(unpushed.stdout.trimmingCharacters(in: .whitespacesAndNewlines)) else { return nil }
        // An unreadable reflog hides nothing: a false alarm beats silent CI.
        let reflog = try? await runner.run(["log", "-g", "--format=%H%x09%gs", "HEAD"], executable: Self.git, workingDirectory: repoPath)
        let preSession = reflog.flatMap { $0.exitCode == 0 ? GhJSON.preSessionCommits(fromReflog: $0.stdout) : nil } ?? []
        return CILocalTip(sha: sha, unpushedCount: count, preSessionCommits: preSession)
    }

    private func headSHA(at repoPath: URL) async throws -> String? {
        let result = try await runner.run(
            ["rev-parse", "HEAD"],
            executable: Self.git,
            workingDirectory: repoPath
        )
        guard result.exitCode == 0 else { return nil }
        let sha = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        return sha.isEmpty ? nil : sha
    }

    public func openIssues(search: String, limit: Int, at repoPath: URL) async throws -> [GhIssue] {
        // Bodies ride along: they cost no measurable time, and a picked issue
        // then needs no second round trip.
        var arguments = ["issue", "list", "--state", "open", "--limit", String(limit), "--json", "number,title,url,labels,updatedAt,body"]
        let query = search.trimmingCharacters(in: .whitespacesAndNewlines)
        if !query.isEmpty {
            arguments += ["--search", query]
        }
        let result = try await runner.run(arguments, executable: ghExecutable, workingDirectory: repoPath)
        guard result.exitCode == 0 else {
            throw GitServiceError.ghCommandFailed(exitCode: result.exitCode, stderr: result.stderr)
        }
        return try GhJSON.issues(from: Data(result.stdout.utf8))
    }

    public func issue(number: Int, at repoPath: URL) async throws -> GhIssue {
        let result = try await runner.run(
            ["issue", "view", String(number), "--json", "number,title,url,labels,updatedAt,body"],
            executable: ghExecutable,
            workingDirectory: repoPath
        )
        guard result.exitCode == 0 else {
            throw GitServiceError.ghCommandFailed(exitCode: result.exitCode, stderr: result.stderr)
        }
        guard let issue = try GhJSON.issues(from: Data(result.stdout.utf8)).first else {
            throw GitServiceError.ghCommandFailed(exitCode: 0, stderr: "gh returned no issue #\(number)")
        }
        return issue
    }

    public func jobLog(jobID: Int, at repoPath: URL) async throws -> String {
        // REST rather than `gh run view --job … --log-failed`, which refuses
        // until every other job in the run has finished too.
        let path = "repos/{owner}/{repo}/actions/jobs/\(jobID)/logs"
        var result = try await runner.run(["api", "--allow-escape-sequences", path], executable: ghExecutable, workingDirectory: repoPath)
        if result.exitCode != 0, result.stderr.localizedCaseInsensitiveContains("unknown flag") {
            result = try await runner.run(["api", path], executable: ghExecutable, workingDirectory: repoPath)
        }
        guard result.exitCode == 0 else {
            throw GitServiceError.ghCommandFailed(exitCode: result.exitCode, stderr: result.stderr)
        }
        return result.stdout
    }
}

import Foundation
import ProcessKit

private func syntheticAddedLines(from text: String) -> [String] {
    var lines = text.components(separatedBy: "\n")
    if lines.last?.isEmpty == true { lines.removeLast() }
    return lines.map { "+\($0)" }
}

public struct GitWorktree: Hashable, Equatable, Sendable {
    public var branch: String
    public var path: URL
    public var isMainWorktree: Bool

    public init(branch: String, path: URL, isMainWorktree: Bool) {
        self.branch = branch
        self.path = path
        self.isMainWorktree = isMainWorktree
    }
}

public struct GitBranch: Hashable, Equatable, Sendable {
    public var name: String
    public var isCurrent: Bool
    public var isRemote: Bool
    public var tipSHA: String
    public var lastCommitDate: Date

    public init(
        name: String,
        isCurrent: Bool,
        isRemote: Bool,
        tipSHA: String,
        lastCommitDate: Date = .distantPast
    ) {
        self.name = name
        self.isCurrent = isCurrent
        self.isRemote = isRemote
        self.tipSHA = tipSHA
        self.lastCommitDate = lastCommitDate
    }
}

public struct GitStatusEntry: Equatable, Sendable {
    public var path: String
    public var indexStatus: Character
    public var worktreeStatus: Character

    public init(path: String, indexStatus: Character, worktreeStatus: Character) {
        self.path = path
        self.indexStatus = indexStatus
        self.worktreeStatus = worktreeStatus
    }

    public var isUntracked: Bool { indexStatus == "?" && worktreeStatus == "?" }
}

public struct GitStatus: Equatable, Sendable {
    public var entries: [GitStatusEntry]
    public var isClean: Bool { entries.isEmpty }

    public init(entries: [GitStatusEntry]) {
        self.entries = entries
    }
}

public struct FileDiffHunk: Equatable, Sendable {
    public var header: String
    public var lines: [String]

    public init(header: String, lines: [String]) {
        self.header = header
        self.lines = lines
    }
}

/// Aggregate line counts for a working tree, in the style of
/// `git diff --shortstat`: how many lines were added and removed across
/// staged, unstaged, and untracked changes. Used for compact `+12 −4`
/// badges in the UI, where the full `FileDiff` payload would be wasteful.
public struct GitDiffStat: Equatable, Sendable {
    public var additions: Int
    public var deletions: Int

    public init(additions: Int, deletions: Int) {
        self.additions = additions
        self.deletions = deletions
    }

    public var isEmpty: Bool { additions == 0 && deletions == 0 }

    public static func + (lhs: GitDiffStat, rhs: GitDiffStat) -> GitDiffStat {
        GitDiffStat(additions: lhs.additions + rhs.additions, deletions: lhs.deletions + rhs.deletions)
    }
}

public struct FileDiff: Equatable, Sendable {
    public enum Stage: String, Equatable, Sendable {
        case staged
        case unstaged
        case untracked
    }

    public var path: String
    public var hunks: [FileDiffHunk]
    public var stage: Stage

    public init(path: String, hunks: [FileDiffHunk], stage: Stage = .unstaged) {
        self.path = path
        self.hunks = hunks
        self.stage = stage
    }

    public var stat: GitDiffStat {
        hunks.reduce(GitDiffStat(additions: 0, deletions: 0)) { total, hunk in
            hunk.lines.reduce(total) { partial, line in
                if line.hasPrefix("+") {
                    return partial + GitDiffStat(additions: 1, deletions: 0)
                }
                if line.hasPrefix("-") {
                    return partial + GitDiffStat(additions: 0, deletions: 1)
                }
                return partial
            }
        }
    }
}

public struct GitChangesSnapshot: Equatable, Sendable {
    public var status: GitStatus
    public var staged: [FileDiff]
    public var unstaged: [FileDiff]
    public var untracked: [FileDiff]

    public init(status: GitStatus, staged: [FileDiff], unstaged: [FileDiff], untracked: [FileDiff]) {
        self.status = status
        self.staged = staged
        self.unstaged = unstaged
        self.untracked = untracked
    }

    public var allDiffs: [FileDiff] { staged + unstaged + untracked }
}

public enum GitServiceError: Error, Equatable, LocalizedError {
    case commandFailed(exitCode: Int32, stderr: String)
    case branchAlreadyExists(String)
    case worktreePathAlreadyExists(URL)
    case nothingToCommit
    case pushRejected(stderr: String)
    case noRemoteConfigured
    case ghNotFound
    case prCreationFailed(exitCode: Int32, stderr: String)
    case commitNotFound(String)

    public var errorDescription: String? {
        switch self {
        case .commandFailed(let exitCode, let stderr):
            let detail = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            return detail.isEmpty ? "git exited with code \(exitCode)" : "git exited with code \(exitCode): \(detail)"
        case .branchAlreadyExists(let branch):
            return "A branch named '\(branch)' already exists."
        case .worktreePathAlreadyExists(let url):
            return "A worktree already exists at \(url.path)."
        case .nothingToCommit:
            return "There are no staged changes to commit."
        case .pushRejected(let stderr):
            let detail = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            return detail.isEmpty ? "The push was rejected." : "The push was rejected: \(detail)"
        case .noRemoteConfigured:
            return "This branch has no configured remote to push to."
        case .ghNotFound:
            return "The GitHub CLI (gh) was not found. Install it to create pull requests."
        case .prCreationFailed(let exitCode, let stderr):
            let detail = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            return detail.isEmpty ? "gh exited with code \(exitCode)" : "gh exited with code \(exitCode): \(detail)"
        case .commitNotFound(let sha):
            return "No commit found for '\(sha)'."
        }
    }
}

public protocol GitServiceProtocol: Sendable {
    func currentBranch(at repoPath: URL) async throws -> String
    func status(at repoPath: URL) async throws -> GitStatus
    func diff(at repoPath: URL, staged: Bool) async throws -> [FileDiff]
    func diffStat(at repoPath: URL) async throws -> GitDiffStat
    func listWorktrees(at repoPath: URL) async throws -> [GitWorktree]
    func createWorktree(basePath: URL, branch: String, destination: URL) async throws -> GitWorktree
    func removeWorktree(at path: URL, in repoPath: URL, branch: String, deleteBranch: Bool) async throws

    /// `git add -- <paths>`.
    func stage(paths: [String], at repoPath: URL) async throws
    /// `git restore --staged -- <paths>`.
    func unstage(paths: [String], at repoPath: URL) async throws
    /// Discards local changes to `paths`. Tracked files are restored from
    /// the index/HEAD (`git restore --worktree`); untracked files are
    /// removed from disk (`git clean -f`), since `restore` cannot undo a
    /// file that was never tracked. Irreversible — callers must confirm.
    func discard(paths: [String], at repoPath: URL) async throws
    /// `git commit -m <message>`. Throws `.nothingToCommit` when there is
    /// nothing staged.
    func commit(message: String, at repoPath: URL) async throws
    /// `git push`, automatically adding `--set-upstream origin <branch>`
    /// when the branch has no upstream configured yet — the caller never
    /// has to decide this itself.
    func push(branch: String, at repoPath: URL) async throws
    /// `git fetch`, used to refresh remote-tracking refs before creating a
    /// worktree from them.
    func fetch(at repoPath: URL) async throws

    /// One page of `git log`, newest first. `ref` defaults to `HEAD` when
    /// `nil`. A repository with no commits yet returns `[]` rather than
    /// throwing — an empty history is a state, not a failure.
    func log(at repoPath: URL, ref: String?, skip: Int, maxCount: Int) async throws -> [GitCommit]

    /// The files a single commit touched, with their diff hunks.
    func commitDetail(sha: String, at repoPath: URL) async throws -> GitCommitDetail

    /// SHAs reachable from `ref` but not from its upstream — the commits that
    /// exist only locally. Best-effort: a branch with no upstream configured
    /// yields `[]` rather than an error, since "no upstream" is normal.
    func unpushedSHAs(at repoPath: URL, ref: String?) async throws -> Set<String>

    /// The `origin` remote's URL, or `nil` when the repo has no origin.
    /// Fetched once per repo and paired with the pure
    /// `GitService.webURL(forRemote:commitSHA:)` to build per-commit links.
    func remoteURL(at repoPath: URL) async throws -> String?

    /// `git rev-parse --git-path hooks` — the hooks directory git will
    /// actually consult, which is *not* `.git/hooks` when `core.hooksPath`
    /// is set at any scope.
    func currentHooksPath(at repoPath: URL) async throws -> String

    /// SHAs reachable from `branch` but not from `base` — i.e. the commits
    /// made on that branch since it diverged. Used to attribute commits to
    /// the agent session working in that branch's worktree.
    ///
    /// Best-effort: an unknown ref yields `[]` rather than an error, because
    /// a session's branch may have been pruned already.
    func commitsOnBranch(_ branch: String, notOn base: String, at repoPath: URL) async throws -> Set<String>

    /// Retrieves commits across all branches with topological ordering for graph visualization.
    func logGraph(at repoPath: URL, maxCount: Int) async throws -> [GitCommit]

    /// Lists all local and remote branches with tip SHAs and current checkout status.
    func branches(at repoPath: URL) async throws -> [GitBranch]

    /// The repository's configured default branch. Prefers `origin/HEAD`,
    /// then conventional local branch names, then the main worktree branch.
    func defaultBranch(at repoPath: URL) async throws -> String

    /// The complete working-copy delta since `HEAD` diverged from `base`.
    /// Includes committed, staged, unstaged, and untracked files.
    func changesCompared(to base: String, at repoPath: URL) async throws -> [GitCommitFileChange]

    /// Working tree versus `HEAD`: everything uncommitted, in the same shape
    /// as `changesCompared(to:at:)` so both review scopes render identically.
    func uncommittedChanges(at repoPath: URL) async throws -> [GitCommitFileChange]

    /// Safe branch mutations used by the session Git sidebar. Callers are
    /// responsible for refusing a checkout while the working tree is dirty.
    func checkout(branch: String, at repoPath: URL) async throws
    func createAndCheckoutBranch(named branch: String, at repoPath: URL) async throws
    func deleteBranch(_ branch: String, force: Bool, at repoPath: URL) async throws

    /// Whether every commit on `branch` is already reachable from `base`.
    func isBranchMerged(_ branch: String, into base: String, at repoPath: URL) async throws -> Bool
}

public extension GitServiceProtocol {
    /// Fetches staged and unstaged states independently, retaining both when
    /// the same file has changes in each area. Untracked text files receive
    /// a synthetic all-added hunk because plain `git diff` omits them.
    func changes(at repoPath: URL) async throws -> GitChangesSnapshot {
        async let statusRequest = status(at: repoPath)
        async let stagedRequest = diff(at: repoPath, staged: true)
        async let unstagedRequest = diff(at: repoPath, staged: false)
        let (status, staged, unstaged) = try await (statusRequest, stagedRequest, unstagedRequest)
        let untracked = status.entries
            .filter(\.isUntracked)
            .map { entry -> FileDiff in
                let url = repoPath.appendingPathComponent(entry.path)
                guard let data = try? Data(contentsOf: url), !data.contains(0) else {
                    return FileDiff(
                        path: entry.path,
                        hunks: [FileDiffHunk(header: "@@ untracked binary file @@", lines: [])],
                        stage: .untracked
                    )
                }
                let text = String(decoding: data, as: UTF8.self)
                let lines = syntheticAddedLines(from: text)
                return FileDiff(
                    path: entry.path,
                    hunks: [FileDiffHunk(header: "@@ new untracked file @@", lines: lines)],
                    stage: .untracked
                )
            }
        return GitChangesSnapshot(status: status, staged: staged, unstaged: unstaged, untracked: untracked)
    }
}

/// Real git integration: every operation shells out via `CommandRunning`
/// (never directly), resolving `git` through `/usr/bin/env` by default so
/// this works regardless of whether git lives at `/usr/bin/git` or a
/// Homebrew path — `gitExecutable` lets Settings override with an explicit
/// path later.
public struct GitService: GitServiceProtocol {
    private let runner: CommandRunning
    private let gitExecutable: URL?

    public init(runner: CommandRunning = ProcessCommandRunner(environmentOverrides: ["GIT_TERMINAL_PROMPT": "0"]), gitExecutable: URL? = nil) {
        self.runner = runner
        self.gitExecutable = gitExecutable
    }

    public func currentBranch(at repoPath: URL) async throws -> String {
        let result = try await run(["rev-parse", "--abbrev-ref", "HEAD"], at: repoPath)
        return result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public func status(at repoPath: URL) async throws -> GitStatus {
        let result = try await run(["status", "--porcelain=v1"], at: repoPath)
        var entries: [GitStatusEntry] = []
        for rawLine in result.stdout.split(separator: "\n", omittingEmptySubsequences: true) {
            let line = String(rawLine)
            guard line.count > 3 else { continue }
            let chars = Array(line)
            let indexStatus = chars[0]
            let worktreeStatus = chars[1]
            var path = String(line.dropFirst(3))
            if let arrowRange = path.range(of: " -> ") {
                path = String(path[arrowRange.upperBound...])
            }
            entries.append(GitStatusEntry(path: path, indexStatus: indexStatus, worktreeStatus: worktreeStatus))
        }
        return GitStatus(entries: entries)
    }

    public func diff(at repoPath: URL, staged: Bool) async throws -> [FileDiff] {
        var args = ["diff", "--no-color"]
        if staged { args.append("--cached") }
        let result = try await run(args, at: repoPath)
        return Self.parseUnifiedDiff(result.stdout).map { diff in
            var tagged = diff
            tagged.stage = staged ? .staged : .unstaged
            return tagged
        }
    }

    /// Sums `--numstat` for staged and unstaged changes (a file modified in
    /// both areas counts each side, matching `changes(at:)`) and counts the
    /// lines of non-binary untracked files as additions, mirroring the
    /// synthetic all-added hunks the diff view shows for new files.
    public func diffStat(at repoPath: URL) async throws -> GitDiffStat {
        async let stagedRequest = run(["diff", "--numstat", "--cached"], at: repoPath)
        async let unstagedRequest = run(["diff", "--numstat"], at: repoPath)
        async let statusRequest = status(at: repoPath)
        let (staged, unstaged, status) = try await (stagedRequest, unstagedRequest, statusRequest)

        var stat = Self.parseNumstat(staged.stdout) + Self.parseNumstat(unstaged.stdout)
        for entry in status.entries where entry.isUntracked {
            let url = repoPath.appendingPathComponent(entry.path)
            guard let data = try? Data(contentsOf: url), !data.contains(0) else { continue }
            stat = stat + GitDiffStat(additions: Self.lineCount(of: data), deletions: 0)
        }
        return stat
    }

    /// Line count the way git counts them: one per `\n`, plus one for a
    /// trailing unterminated line. (Splitting on `\n` would over-count
    /// newline-terminated files by one.)
    private static func lineCount(of data: Data) -> Int {
        let newlines = data.reduce(0) { $0 + ($1 == 0x0A ? 1 : 0) }
        let endsWithNewline = data.last == 0x0A
        return data.isEmpty || endsWithNewline ? newlines : newlines + 1
    }

    public func listWorktrees(at repoPath: URL) async throws -> [GitWorktree] {
        let result = try await run(["worktree", "list", "--porcelain"], at: repoPath)
        var worktrees: [GitWorktree] = []
        var currentPath: URL?
        var currentBranch: String?

        func flush() {
            if let path = currentPath {
                let branch = currentBranch ?? "(detached)"
                worktrees.append(GitWorktree(branch: branch, path: path, isMainWorktree: worktrees.isEmpty))
            }
            currentPath = nil
            currentBranch = nil
        }

        for rawLine in result.stdout.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(rawLine)
            if line.isEmpty {
                flush()
            } else if line.hasPrefix("worktree ") {
                currentPath = URL(fileURLWithPath: String(line.dropFirst("worktree ".count)))
            } else if line.hasPrefix("branch ") {
                let ref = String(line.dropFirst("branch ".count))
                currentBranch = ref.hasPrefix("refs/heads/") ? String(ref.dropFirst("refs/heads/".count)) : ref
            }
        }
        flush()
        return worktrees
    }

    public func createWorktree(basePath: URL, branch: String, destination: URL) async throws -> GitWorktree {
        do {
            _ = try await run(["worktree", "add", "-b", branch, destination.path], at: basePath)
        } catch let GitServiceError.commandFailed(_, stderr) {
            if stderr.contains("already exists") && stderr.contains(branch) {
                throw GitServiceError.branchAlreadyExists(branch)
            }
            if stderr.lowercased().contains("already exists") {
                throw GitServiceError.worktreePathAlreadyExists(destination)
            }
            throw GitServiceError.commandFailed(exitCode: -1, stderr: stderr)
        }
        return GitWorktree(branch: branch, path: destination, isMainWorktree: false)
    }

    public func removeWorktree(at path: URL, in repoPath: URL, branch: String, deleteBranch: Bool) async throws {
        var worktreeFailure: GitServiceError?
        do {
            _ = try await run(["worktree", "remove", path.path, "--force"], at: repoPath)
        } catch let GitServiceError.commandFailed(exitCode, stderr) {
            worktreeFailure = .commandFailed(exitCode: exitCode, stderr: stderr)
        }

        if worktreeFailure != nil {
            // `worktree remove` fails when the directory is already gone or
            // its metadata is stale (e.g. deleted manually or by a previous
            // partial cleanup). Recover by removing any lingering directory
            // and pruning the stale worktree record from git, so the session
            // deletion still cleans up on disk.
            //
            // `FileManager.removeItem` used to do this recursively, but it
            // aborts the whole recursive delete on the first item it can't
            // remove — leaving everything *before* that item gone and
            // everything after it (including the directory itself) behind.
            // That's exactly how orphaned worktree directories with a
            // leftover `.claude/` folder and no `.git` file were found on
            // disk: git had already unregistered the worktree, but the
            // directory removal choked partway through. `rm -rf` keeps
            // going past an unremovable item instead of stopping the whole
            // walk, so it clears everything it can rather than nothing.
            if FileManager.default.fileExists(atPath: path.path) {
                let cleanup = Process()
                cleanup.executableURL = URL(fileURLWithPath: "/bin/rm")
                cleanup.arguments = ["-rf", "--", path.path]
                try? cleanup.run()
                cleanup.waitUntilExit()
            }
            _ = try? await run(["worktree", "prune"], at: repoPath)
            if !FileManager.default.fileExists(atPath: path.path) {
                worktreeFailure = nil
            }
        }

        if deleteBranch {
            // Best-effort: deleting the branch is independent of the
            // directory state and must never fail the session cleanup on
            // its own.
            _ = try? await run(["branch", "-D", branch], at: repoPath)
        }

        if let worktreeFailure {
            throw worktreeFailure
        }
    }

    public func stage(paths: [String], at repoPath: URL) async throws {
        guard !paths.isEmpty else { return }
        _ = try await run(["add", "--"] + paths, at: repoPath)
    }

    public func unstage(paths: [String], at repoPath: URL) async throws {
        guard !paths.isEmpty else { return }
        _ = try await run(["restore", "--staged", "--"] + paths, at: repoPath)
    }

    public func discard(paths: [String], at repoPath: URL) async throws {
        guard !paths.isEmpty else { return }
        let entries = try await status(at: repoPath).entries
        let untrackedSet = Set(entries.filter(\.isUntracked).map(\.path))
        let untracked = paths.filter { untrackedSet.contains($0) }
        let tracked = paths.filter { !untrackedSet.contains($0) }
        if !tracked.isEmpty {
            _ = try await run(["restore", "--worktree", "--"] + tracked, at: repoPath)
        }
        if !untracked.isEmpty {
            _ = try await run(["clean", "-f", "--"] + untracked, at: repoPath)
        }
    }

    public func commit(message: String, at repoPath: URL) async throws {
        // Raw, not the throwing `run(_:at:)` wrapper: `git commit` writes
        // "nothing to commit" to *stdout*, not stderr, and the wrapper only
        // carries stderr into its thrown error.
        let result = try await runRaw(["commit", "-m", message], at: repoPath)
        guard result.exitCode == 0 else {
            if result.stdout.contains("nothing to commit") || result.stderr.contains("nothing to commit") {
                throw GitServiceError.nothingToCommit
            }
            throw GitServiceError.commandFailed(exitCode: result.exitCode, stderr: result.stderr)
        }
    }

    public func push(branch: String, at repoPath: URL) async throws {
        let hasUpstream = (try? await run(["rev-parse", "--abbrev-ref", "--symbolic-full-name", "@{u}"], at: repoPath)) != nil
        var args = ["push"]
        if !hasUpstream {
            args += ["--set-upstream", "origin", branch]
        }
        do {
            _ = try await run(args, at: repoPath)
        } catch let GitServiceError.commandFailed(exitCode, stderr) {
            let lowered = stderr.lowercased()
            if lowered.contains("rejected") || lowered.contains("non-fast-forward") {
                throw GitServiceError.pushRejected(stderr: stderr)
            }
            if lowered.contains("no configured push destination") || lowered.contains("does not appear to be a git repository") {
                throw GitServiceError.noRemoteConfigured
            }
            throw GitServiceError.commandFailed(exitCode: exitCode, stderr: stderr)
        }
    }

    public func fetch(at repoPath: URL) async throws {
        _ = try await run(["fetch"], at: repoPath)
    }

    public func log(at repoPath: URL, ref: String? = nil, skip: Int = 0, maxCount: Int = 100) async throws -> [GitCommit] {
        var args = [
            "log",
            "--no-color",
            "--decorate=full",
            "--numstat",
            "--skip=\(max(0, skip))",
            "--max-count=\(max(1, maxCount))",
            "--format=\(Self.logFormat)",
        ]
        if let ref, !ref.isEmpty { args.append(ref) }
        // Disambiguates a ref that shares its name with a file on disk.
        args.append("--")

        // Raw, not the throwing wrapper: a repository with no commits makes
        // `git log` exit non-zero, and that is an empty history rather than
        // an error worth showing the user.
        let result = try await runRaw(args, at: repoPath)
        guard result.exitCode == 0 else {
            if Self.indicatesEmptyHistory(result.stderr) { return [] }
            throw GitServiceError.commandFailed(exitCode: result.exitCode, stderr: result.stderr)
        }
        return Self.parseLog(result.stdout)
    }

    public func commitDetail(sha: String, at repoPath: URL) async throws -> GitCommitDetail {
        // Three independent reads of the same commit — concurrent for the
        // same reason `changes(at:)` is.
        async let logRequest = run(
            ["log", "--no-color", "--decorate=full", "--numstat", "--max-count=1",
             "--format=\(Self.logFormat)", sha, "--"],
            at: repoPath
        )
        async let patchRequest = run(
            ["show", "--no-color", "--format=", "--patch", "--find-renames", sha, "--"],
            at: repoPath
        )
        async let nameStatusRequest = run(
            ["show", "--no-color", "--format=", "--name-status", "--find-renames", sha, "--"],
            at: repoPath
        )
        let (logResult, patchResult, nameStatusResult) =
            try await (logRequest, patchRequest, nameStatusRequest)

        guard let commit = Self.parseLog(logResult.stdout).first else {
            throw GitServiceError.commitNotFound(sha)
        }

        // `--name-status` is authoritative for *what happened* to each file;
        // the patch supplies the hunks. Keyed on the post-change path, which
        // is what both report for renames.
        let hunksByPath = Dictionary(
            Self.parseUnifiedDiff(patchResult.stdout).map { ($0.path, $0.hunks) },
            uniquingKeysWith: { first, _ in first }
        )
        let files = Self.parseNameStatus(nameStatusResult.stdout).map { change -> GitCommitFileChange in
            var resolved = change
            resolved.hunks = hunksByPath[change.path] ?? []
            return resolved
        }
        return GitCommitDetail(commit: commit, files: files)
    }

    public func unpushedSHAs(at repoPath: URL, ref: String? = nil) async throws -> Set<String> {
        let target = ref.flatMap { $0.isEmpty ? nil : $0 } ?? "HEAD"
        let result = try await runRaw(["rev-list", "\(target)@{u}..\(target)"], at: repoPath)
        guard result.exitCode == 0 else { return [] }
        return Set(result.stdout.split(separator: "\n").map(String.init))
    }

    public func commitsOnBranch(_ branch: String, notOn base: String, at repoPath: URL) async throws -> Set<String> {
        guard !branch.isEmpty, !base.isEmpty, branch != base else { return [] }
        let result = try await runRaw(["rev-list", "\(base)..\(branch)"], at: repoPath)
        guard result.exitCode == 0 else { return [] }
        return Set(result.stdout.split(separator: "\n").map(String.init))
    }

    public func currentHooksPath(at repoPath: URL) async throws -> String {
        let result = try await run(["rev-parse", "--git-path", "hooks"], at: repoPath)
        return result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public func remoteURL(at repoPath: URL) async throws -> String? {
        let result = try await runRaw(["remote", "get-url", "origin"], at: repoPath)
        guard result.exitCode == 0 else { return nil }
        let trimmed = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    public func logGraph(at repoPath: URL, maxCount: Int = 500) async throws -> [GitCommit] {
        let args = [
            "log",
            "--all",
            "--topo-order",
            "--no-color",
            "--decorate=full",
            // Same single-invocation reasoning as `log`: the graph rows show a
            // diff stat, and asking for it here costs one flag instead of one
            // subprocess per visible commit.
            "--numstat",
            "--max-count=\(max(1, maxCount))",
            "--format=\(Self.logFormat)",
            "--",
        ]
        let result = try await runRaw(args, at: repoPath)
        guard result.exitCode == 0 else {
            if Self.indicatesEmptyHistory(result.stderr) { return [] }
            throw GitServiceError.commandFailed(exitCode: result.exitCode, stderr: result.stderr)
        }
        return Self.parseLog(result.stdout)
    }

    public func branches(at repoPath: URL) async throws -> [GitBranch] {
        let format = "%(refname:short)%09%(HEAD)%09%(objectname)%09%(refname)%09%(committerdate:unix)"
        let args = ["for-each-ref", "--format=\(format)", "refs/heads", "refs/remotes"]
        let result = try await runRaw(args, at: repoPath)
        guard result.exitCode == 0 else { return [] }
        return Self.parseBranches(result.stdout)
    }

    public func defaultBranch(at repoPath: URL) async throws -> String {
        let remoteHead = try await runRaw(
            ["symbolic-ref", "--quiet", "--short", "refs/remotes/origin/HEAD"],
            at: repoPath
        )
        if remoteHead.exitCode == 0 {
            let remoteName = remoteHead.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
            let localName = remoteName.hasPrefix("origin/")
                ? String(remoteName.dropFirst("origin/".count))
                : remoteName
            let localRef = try await runRaw(
                ["show-ref", "--verify", "--quiet", "refs/heads/\(localName)"],
                at: repoPath
            )
            return localRef.exitCode == 0 ? localName : remoteName
        }

        for candidate in ["main", "master"] {
            let result = try await runRaw(
                ["show-ref", "--verify", "--quiet", "refs/heads/\(candidate)"],
                at: repoPath
            )
            if result.exitCode == 0 { return candidate }
        }

        if let mainWorktree = try await listWorktrees(at: repoPath).first(where: \.isMainWorktree),
           mainWorktree.branch != "(detached)" {
            return mainWorktree.branch
        }
        return try await currentBranch(at: repoPath)
    }

    public func changesCompared(to base: String, at repoPath: URL) async throws -> [GitCommitFileChange] {
        let mergeBase = try await run(["merge-base", "HEAD", base], at: repoPath)
            .stdout
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !mergeBase.isEmpty else { return [] }
        return try await changes(against: mergeBase, at: repoPath)
    }

    /// Working tree versus `HEAD` — everything not yet committed, staged or
    /// not, plus untracked files.
    ///
    /// The same shape as `changesCompared(to:at:)` rather than
    /// `changes(at:)`'s `GitChangesSnapshot`, so a caller that offers both
    /// "all branch work" and "uncommitted" has one type to render. A snapshot
    /// splits by staging area and reports a part-staged file twice, which is
    /// the right answer for a staging UI and the wrong one for reviewing a
    /// file's current state.
    ///
    /// In a repository with no commits there is no `HEAD` to diff against, so
    /// every file is reported as untracked and therefore added.
    public func uncommittedChanges(at repoPath: URL) async throws -> [GitCommitFileChange] {
        let head = try? await run(["rev-parse", "--verify", "HEAD"], at: repoPath)
        guard head != nil else {
            return try await untrackedChanges(at: repoPath, excluding: [])
        }
        return try await changes(against: "HEAD", at: repoPath)
    }

    /// The shared body behind `changesCompared(to:at:)` and
    /// `uncommittedChanges(at:)`: the working tree diffed against `ref`, with
    /// untracked files appended as whole-file additions.
    private func changes(against ref: String, at repoPath: URL) async throws -> [GitCommitFileChange] {
        async let patchRequest = run(
            ["diff", "--no-color", "--find-renames", ref, "--"],
            at: repoPath
        )
        async let nameStatusRequest = run(
            ["diff", "--no-color", "--name-status", "--find-renames", ref, "--"],
            at: repoPath
        )
        async let statusRequest = status(at: repoPath)
        let (patch, nameStatus, workingStatus) = try await (
            patchRequest,
            nameStatusRequest,
            statusRequest
        )

        let hunksByPath = Dictionary(
            Self.parseUnifiedDiff(patch.stdout).map { ($0.path, $0.hunks) },
            uniquingKeysWith: { first, _ in first }
        )
        var changes = Self.parseNameStatus(nameStatus.stdout).map { change -> GitCommitFileChange in
            var resolved = change
            resolved.hunks = hunksByPath[change.path] ?? []
            return resolved
        }

        let knownPaths = Set(changes.map(\.path))
        changes.append(contentsOf: try await untrackedChanges(at: repoPath, excluding: knownPaths, status: workingStatus))
        return changes
    }

    /// Untracked files rendered as whole-file additions, since git emits no
    /// patch for a file it does not track.
    private func untrackedChanges(
        at repoPath: URL,
        excluding knownPaths: Set<String>,
        status workingStatus: GitStatus? = nil
    ) async throws -> [GitCommitFileChange] {
        let resolved: GitStatus
        if let workingStatus {
            resolved = workingStatus
        } else {
            resolved = try await status(at: repoPath)
        }
        var changes: [GitCommitFileChange] = []
        for entry in resolved.entries where entry.isUntracked && !knownPaths.contains(entry.path) {
            let fileURL = repoPath.appendingPathComponent(entry.path)
            let hunks: [FileDiffHunk]
            if let data = try? Data(contentsOf: fileURL), !data.contains(0) {
                let text = String(decoding: data, as: UTF8.self)
                let lines = syntheticAddedLines(from: text)
                hunks = [FileDiffHunk(header: "@@ new untracked file @@", lines: lines)]
            } else {
                hunks = [FileDiffHunk(header: "@@ untracked binary file @@", lines: [])]
            }
            changes.append(GitCommitFileChange(path: entry.path, kind: .added, hunks: hunks))
        }
        return changes
    }

    public func checkout(branch: String, at repoPath: URL) async throws {
        _ = try await run(["switch", branch], at: repoPath)
    }

    public func createAndCheckoutBranch(named branch: String, at repoPath: URL) async throws {
        do {
            _ = try await run(["switch", "-c", branch], at: repoPath)
        } catch let GitServiceError.commandFailed(_, stderr) {
            if stderr.contains("already exists") {
                throw GitServiceError.branchAlreadyExists(branch)
            }
            throw GitServiceError.commandFailed(exitCode: -1, stderr: stderr)
        }
    }

    public func deleteBranch(_ branch: String, force: Bool, at repoPath: URL) async throws {
        _ = try await run(["branch", force ? "-D" : "-d", branch], at: repoPath)
    }

    public func isBranchMerged(_ branch: String, into base: String, at repoPath: URL) async throws -> Bool {
        let result = try await runRaw(["merge-base", "--is-ancestor", branch, base], at: repoPath)
        switch result.exitCode {
        case 0: return true
        case 1: return false
        default:
            throw GitServiceError.commandFailed(exitCode: result.exitCode, stderr: result.stderr)
        }
    }

    public static func parseBranches(_ output: String) -> [GitBranch] {
        var branches: [GitBranch] = []
        for line in output.split(separator: "\n", omittingEmptySubsequences: true) {
            let parts = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
            guard parts.count >= 4 else { continue }
            let name = parts[0]
            let isCurrent = parts[1] == "*"
            let tipSHA = parts[2]
            let fullRef = parts[3]
            let isRemote = fullRef.hasPrefix("refs/remotes/")
            let lastCommitDate = parts.count >= 5
                ? TimeInterval(parts[4]).map(Date.init(timeIntervalSince1970:)) ?? .distantPast
                : .distantPast
            if name.hasSuffix("/HEAD") { continue }
            branches.append(GitBranch(
                name: name,
                isCurrent: isCurrent,
                isRemote: isRemote,
                tipSHA: tipSHA,
                lastCommitDate: lastCommitDate
            ))
        }
        return branches
    }

    /// git words this differently depending on whether HEAD is an unborn
    /// branch or the revision is simply unresolvable, so both are matched.
    private static func indicatesEmptyHistory(_ stderr: String) -> Bool {
        let lowered = stderr.lowercased()
        return lowered.contains("does not have any commits")
            || lowered.contains("bad default revision")
            || lowered.contains("unknown revision")
    }

    /// Runs git and returns the raw result regardless of exit code — for
    /// callers (like `commit`) that need to inspect stdout/stderr themselves
    /// to distinguish failure reasons `run(_:at:)`'s single `stderr`-only
    /// error can't carry.
    private func runRaw(_ arguments: [String], at path: URL) async throws -> CommandResult {
        if let gitExecutable {
            return try await runner.run(arguments, executable: gitExecutable, workingDirectory: path)
        } else {
            return try await runner.run(["git"] + arguments, executable: URL(fileURLWithPath: "/usr/bin/env"), workingDirectory: path)
        }
    }

    private func run(_ arguments: [String], at path: URL) async throws -> CommandResult {
        let result = try await runRaw(arguments, at: path)
        guard result.exitCode == 0 else {
            throw GitServiceError.commandFailed(exitCode: result.exitCode, stderr: result.stderr)
        }
        return result
    }

    /// Parses `git diff --numstat` output: one `added<TAB>deleted<TAB>path`
    /// line per file, with `-` in place of a count for binary files (which
    /// contribute zero). `public` for the same direct unit-testability
    /// reason as `parseUnifiedDiff`.
    public static func parseNumstat(_ raw: String) -> GitDiffStat {
        var stat = GitDiffStat(additions: 0, deletions: 0)
        for rawLine in raw.split(separator: "\n", omittingEmptySubsequences: true) {
            let fields = rawLine.split(separator: "\t")
            guard fields.count >= 2,
                  let added = Int(fields[0]),
                  let deleted = Int(fields[1]) else { continue }
            stat = stat + GitDiffStat(additions: added, deletions: deleted)
        }
        return stat
    }

    /// `public` (not just `internal`) specifically so it's directly unit
    /// testable with crafted multi-file/multi-hunk input — exercising this
    /// only through a real git repo would make edge cases hard to set up
    /// precisely.
    public static func parseUnifiedDiff(_ raw: String) -> [FileDiff] {
        var diffs: [FileDiff] = []
        var currentPath: String?
        var currentHunks: [FileDiffHunk] = []
        var currentHunkHeader: String?
        var currentHunkLines: [String] = []

        func flushHunk() {
            if let header = currentHunkHeader {
                currentHunks.append(FileDiffHunk(header: header, lines: currentHunkLines))
            }
            currentHunkHeader = nil
            currentHunkLines = []
        }

        func flushFile() {
            flushHunk()
            if let path = currentPath {
                diffs.append(FileDiff(path: path, hunks: currentHunks))
            }
            currentPath = nil
            currentHunks = []
        }

        for line in raw.split(separator: "\n", omittingEmptySubsequences: false) {
            let text = String(line)
            if text.hasPrefix("diff --git ") {
                flushFile()
                let components = text.split(separator: " ")
                if let destination = components.last {
                    let rawPath = String(destination)
                    currentPath = rawPath.hasPrefix("b/") ? String(rawPath.dropFirst(2)) : rawPath
                }
            } else if text.hasPrefix("+++ b/") {
                currentPath = String(text.dropFirst("+++ b/".count))
            } else if text.hasPrefix("+++ /dev/null"), currentPath == nil {
                currentPath = nil
            } else if text.hasPrefix("@@ ") {
                flushHunk()
                currentHunkHeader = text
            } else if currentHunkHeader != nil {
                currentHunkLines.append(text)
            }
        }
        flushFile()
        return diffs
    }
}

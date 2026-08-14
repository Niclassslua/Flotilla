import Foundation

public struct GitWorktree: Equatable, Sendable {
    public var branch: String
    public var path: URL
    public var isMainWorktree: Bool

    public init(branch: String, path: URL, isMainWorktree: Bool) {
        self.branch = branch
        self.path = path
        self.isMainWorktree = isMainWorktree
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

public enum GitServiceError: Error, Equatable {
    case commandFailed(exitCode: Int32, stderr: String)
    case branchAlreadyExists(String)
    case worktreePathAlreadyExists(URL)
}

public protocol GitServiceProtocol: Sendable {
    func currentBranch(at repoPath: URL) async throws -> String
    func status(at repoPath: URL) async throws -> GitStatus
    func diff(at repoPath: URL, staged: Bool) async throws -> [FileDiff]
    func listWorktrees(at repoPath: URL) async throws -> [GitWorktree]
    func createWorktree(basePath: URL, branch: String, destination: URL) async throws -> GitWorktree
    func removeWorktree(at path: URL, in repoPath: URL, branch: String, deleteBranch: Bool) async throws
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
                let lines = text.split(separator: "\n", omittingEmptySubsequences: false).map { "+\($0)" }
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

    public init(runner: CommandRunning = ProcessCommandRunner(), gitExecutable: URL? = nil) {
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
        _ = try await run(["worktree", "remove", path.path, "--force"], at: repoPath)
        if deleteBranch {
            _ = try await run(["branch", "-D", branch], at: repoPath)
        }
    }

    private func run(_ arguments: [String], at path: URL) async throws -> CommandResult {
        let result: CommandResult
        if let gitExecutable {
            result = try await runner.run(arguments, executable: gitExecutable, workingDirectory: path)
        } else {
            result = try await runner.run(["git"] + arguments, executable: URL(fileURLWithPath: "/usr/bin/env"), workingDirectory: path)
        }
        guard result.exitCode == 0 else {
            throw GitServiceError.commandFailed(exitCode: result.exitCode, stderr: result.stderr)
        }
        return result
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

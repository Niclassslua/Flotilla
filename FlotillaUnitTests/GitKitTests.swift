import XCTest
import GitKit
import ProcessKit

/// Crafted multi-file/multi-hunk input, exercised directly rather than
/// only through a real git repo — precise edge cases (multiple hunks in
/// one file, multiple files in one diff) are much easier to set up this way.
final class UnifiedDiffParsingTests: XCTestCase {
    func testParseUnifiedDiffShapes() {
        let multi = """
        diff --git a/file1.txt b/file1.txt
        index abc123..def456 100644
        --- a/file1.txt
        +++ b/file1.txt
        @@ -1,3 +1,4 @@
         line1
        -line2
        +line2 modified
        +line2b
         line3
        @@ -10,2 +11,2 @@
        -old10
        +new10
         line11
        diff --git a/file2.txt b/file2.txt
        index 111..222 100644
        --- a/file2.txt
        +++ b/file2.txt
        @@ -1,1 +1,1 @@
        -hello
        +world
        """

        let diffs = GitService.parseUnifiedDiff(multi)
        XCTAssertEqual(diffs.count, 2)
        XCTAssertEqual(diffs[0].path, "file1.txt")
        XCTAssertEqual(diffs[0].hunks.count, 2)
        XCTAssertEqual(diffs[0].hunks[0].header, "@@ -1,3 +1,4 @@")
        XCTAssertEqual(diffs[0].hunks[0].lines, [" line1", "-line2", "+line2 modified", "+line2b", " line3"])
        XCTAssertEqual(diffs[0].hunks[1].header, "@@ -10,2 +11,2 @@")
        XCTAssertEqual(diffs[0].hunks[1].lines, ["-old10", "+new10", " line11"])
        XCTAssertEqual(diffs[1].path, "file2.txt")
        XCTAssertEqual(diffs[1].hunks.count, 1)
        XCTAssertEqual(diffs[1].hunks[0].lines, ["-hello", "+world"])

        XCTAssertTrue(GitService.parseUnifiedDiff("").isEmpty)

        let deleted = """
        diff --git a/obsolete.swift b/obsolete.swift
        deleted file mode 100644
        index 1234567..0000000
        --- a/obsolete.swift
        +++ /dev/null
        @@ -1 +0,0 @@
        -let obsolete = true
        """
        let diff = GitService.parseUnifiedDiff(deleted).first
        XCTAssertEqual(diff?.path, "obsolete.swift")
        XCTAssertEqual(diff?.hunks.first?.lines, ["-let obsolete = true"])
    }
}

final class NumstatParsingTests: XCTestCase {
    func testParseNumstatShapes() {
        XCTAssertEqual(
            GitService.parseNumstat("10\t2\tfile1.swift\n3\t0\tfile2.swift\n"),
            GitDiffStat(files: 2, additions: 13, deletions: 2)
        )
        XCTAssertEqual(
            GitService.parseNumstat("-\t-\timage.png\n5\t1\tcode.swift\n"),
            GitDiffStat(files: 1, additions: 5, deletions: 1)
        )
        XCTAssertEqual(GitService.parseNumstat(""), GitDiffStat(additions: 0, deletions: 0))
    }
}

final class BranchParsingTests: XCTestCase {
    func testParsesLastCommitDateAndFiltersRemoteHead() throws {
        let raw = "main\t*\tabc123\trefs/heads/main\t1700000000\norigin/HEAD\t \tabc123\trefs/remotes/origin/HEAD\t1700000001\n"

        let branch = try XCTUnwrap(GitService.parseBranches(raw).first)

        XCTAssertEqual(branch.name, "main")
        XCTAssertTrue(branch.isCurrent)
        XCTAssertEqual(branch.lastCommitDate, Date(timeIntervalSince1970: 1_700_000_000))
        XCTAssertEqual(GitService.parseBranches(raw).count, 1)
    }
}

/// Exercises the real `GitService` against an actual git repository created
/// fresh in a temp directory for each test — real confidence, not just
/// argument-string assertions.
final class GitServiceRealRepoTests: XCTestCase {
    private var repoPath: URL!
    private var worktreeBase: URL!
    private let runner = ProcessCommandRunner()
    private let service = GitService()

    override func setUp() async throws {
        try await super.setUp()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("flotilla-gittests-\(UUID().uuidString)")
        repoPath = root.appendingPathComponent("repo")
        worktreeBase = root.appendingPathComponent("worktrees")
        try FileManager.default.createDirectory(at: repoPath, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: worktreeBase, withIntermediateDirectories: true)

        try await git(["init", "-b", "main"])
        try "hello\n".write(to: repoPath.appendingPathComponent("README.md"), atomically: true, encoding: .utf8)
        try await git(["add", "README.md"])
        try await git(["-c", "user.name=Flotilla Tests", "-c", "user.email=flotilla-tests@example.com", "commit", "-m", "init"])
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: repoPath.deletingLastPathComponent())
        try await super.tearDown()
    }

    @discardableResult
    private func git(_ args: [String]) async throws -> CommandResult {
        try await runner.run(["git"] + args, executable: URL(fileURLWithPath: "/usr/bin/env"), workingDirectory: repoPath)
    }

    func testCurrentDefaultBranchAndWorkingTreeStatus() async throws {
        let current = try await service.currentBranch(at: repoPath)
        XCTAssertEqual(current, "main")

        try await git(["switch", "-c", "feature"])
        let defaultBranch = try await service.defaultBranch(at: repoPath)
        XCTAssertEqual(defaultBranch, "main")
        try await git(["switch", "main"])

        let clean = try await service.diffStat(at: repoPath)
        XCTAssertEqual(clean, GitDiffStat(additions: 0, deletions: 0))

        try "changed\n".write(to: repoPath.appendingPathComponent("README.md"), atomically: true, encoding: .utf8)
        try "new\n".write(to: repoPath.appendingPathComponent("NEW.md"), atomically: true, encoding: .utf8)
        let status = try await service.status(at: repoPath)
        let paths = Set(status.entries.map(\.path))
        XCTAssertTrue(paths.contains("README.md"))
        XCTAssertTrue(paths.contains("NEW.md"))
        XCTAssertTrue(status.entries.first(where: { $0.path == "NEW.md" })?.isUntracked ?? false)
    }

    func testChangesSnapshotRetainsStagedAndUnstagedVersionsAndUntrackedText() async throws {
        try "staged\n".write(to: repoPath.appendingPathComponent("README.md"), atomically: true, encoding: .utf8)
        try await git(["add", "README.md"])
        try "staged then modified\n".write(to: repoPath.appendingPathComponent("README.md"), atomically: true, encoding: .utf8)
        try "new file\n".write(to: repoPath.appendingPathComponent("NEW.md"), atomically: true, encoding: .utf8)

        let snapshot = try await service.changes(at: repoPath)

        XCTAssertEqual(snapshot.staged.map(\.path), ["README.md"])
        XCTAssertEqual(snapshot.unstaged.map(\.path), ["README.md"])
        XCTAssertEqual(snapshot.untracked.map(\.path), ["NEW.md"])
        XCTAssertEqual(snapshot.staged.first?.stage, .staged)
        XCTAssertEqual(snapshot.unstaged.first?.stage, .unstaged)
        XCTAssertEqual(snapshot.untracked.first?.stage, .untracked)
        XCTAssertTrue(snapshot.untracked.first?.hunks.first?.lines.contains("+new file") == true)
    }

    func testDiffStatSumsStagedUnstagedAndUntracked() async throws {
        // README.md starts as "hello\n" (one line) from setUp.
        try "changed\nmore\n".write(to: repoPath.appendingPathComponent("README.md"), atomically: true, encoding: .utf8)
        try await git(["add", "README.md"])
        try "changed\nmore\nextra\n".write(to: repoPath.appendingPathComponent("README.md"), atomically: true, encoding: .utf8)
        try "one\ntwo\nthree\n".write(to: repoPath.appendingPathComponent("NEW.md"), atomically: true, encoding: .utf8)

        let stat = try await service.diffStat(at: repoPath)

        // Staged: +2 −1. Unstaged: +1 −0. Untracked NEW.md: +3 −0.
        // Files: README.md and NEW.md, one entry each in git status.
        XCTAssertEqual(stat, GitDiffStat(files: 2, additions: 6, deletions: 1))
    }

    func testChangesComparedIncludesCommittedWorkingTreeAndUntrackedChanges() async throws {
        try await git(["switch", "-c", "feature"])
        try "committed\n".write(
            to: repoPath.appendingPathComponent("Committed.swift"),
            atomically: true,
            encoding: .utf8
        )
        try await git(["add", "Committed.swift"])
        try await commit("Add committed file")

        try "changed\n".write(
            to: repoPath.appendingPathComponent("README.md"),
            atomically: true,
            encoding: .utf8
        )
        try "untracked\n".write(
            to: repoPath.appendingPathComponent("Untracked.swift"),
            atomically: true,
            encoding: .utf8
        )

        let changes = try await service.changesCompared(to: "main", at: repoPath)
        let byPath = Dictionary(uniqueKeysWithValues: changes.map { ($0.path, $0) })

        XCTAssertEqual(byPath["Committed.swift"]?.kind, .added)
        XCTAssertEqual(byPath["README.md"]?.kind, .modified)
        XCTAssertEqual(byPath["Untracked.swift"]?.kind, .added)
        XCTAssertEqual(byPath["Committed.swift"]?.stat.additions, 1)
        XCTAssertEqual(byPath["README.md"]?.stat.deletions, 1)
        XCTAssertEqual(byPath["Untracked.swift"]?.stat.additions, 1)
    }

    func testCreateCheckoutMergeAssessmentAndDeleteLocalBranch() async throws {
        try await service.createAndCheckoutBranch(named: "feature", at: repoPath)
        let currentBranch = try await service.currentBranch(at: repoPath)
        let initiallyMerged = try await service.isBranchMerged("feature", into: "main", at: repoPath)
        XCTAssertEqual(currentBranch, "feature")
        XCTAssertTrue(initiallyMerged)

        try "feature\n".write(
            to: repoPath.appendingPathComponent("Feature.swift"),
            atomically: true,
            encoding: .utf8
        )
        try await git(["add", "Feature.swift"])
        try await commit("Feature work")
        let mergedAfterCommit = try await service.isBranchMerged("feature", into: "main", at: repoPath)
        XCTAssertFalse(mergedAfterCommit)

        try await service.checkout(branch: "main", at: repoPath)
        try await service.deleteBranch("feature", force: true, at: repoPath)

        let remaining = try await service.branches(at: repoPath)
        XCTAssertFalse(remaining.contains { $0.name == "feature" })
    }

    func testCreateWorktreeSucceedsAndAppearsInList() async throws {
        let destination = worktreeBase.appendingPathComponent("feature-x")
        let worktree = try await service.createWorktree(basePath: repoPath, branch: "feature-x", destination: destination)

        XCTAssertEqual(worktree.branch, "feature-x")
        XCTAssertTrue(FileManager.default.fileExists(atPath: destination.path))

        let worktrees = try await service.listWorktrees(at: repoPath)
        XCTAssertEqual(worktrees.count, 2)
        XCTAssertTrue(worktrees[0].isMainWorktree)
        XCTAssertTrue(worktrees.contains { $0.branch == "feature-x" && !$0.isMainWorktree })
    }

    func testCreateWorktreeFailsWhenBranchAlreadyExists() async throws {
        let destination = worktreeBase.appendingPathComponent("dup-branch")
        _ = try await service.createWorktree(basePath: repoPath, branch: "dup-branch", destination: destination)

        let secondDestination = worktreeBase.appendingPathComponent("dup-branch-2")
        do {
            _ = try await service.createWorktree(basePath: repoPath, branch: "dup-branch", destination: secondDestination)
            XCTFail("expected branchAlreadyExists error")
        } catch GitServiceError.branchAlreadyExists(let branch) {
            XCTAssertEqual(branch, "dup-branch")
        }
    }

    func testRemoveWorktreeCleansUpDirectoryAndBranch() async throws {
        let destination = worktreeBase.appendingPathComponent("to-remove")
        _ = try await service.createWorktree(basePath: repoPath, branch: "to-remove", destination: destination)
        XCTAssertTrue(FileManager.default.fileExists(atPath: destination.path))

        try await service.removeWorktree(at: destination, in: repoPath, branch: "to-remove", deleteBranch: true)

        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
        let branches = try await git(["branch", "--list", "to-remove"])
        XCTAssertTrue(branches.stdout.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

        let worktrees = try await service.listWorktrees(at: repoPath)
        XCTAssertEqual(worktrees.count, 1)
    }

    func testRemoveWorktreeRecoversWhenDirectoryAlreadyGone() async throws {
        let destination = worktreeBase.appendingPathComponent("stale")
        _ = try await service.createWorktree(basePath: repoPath, branch: "stale", destination: destination)
        XCTAssertTrue(FileManager.default.fileExists(atPath: destination.path))

        try FileManager.default.removeItem(at: destination)

        try await service.removeWorktree(at: destination, in: repoPath, branch: "stale", deleteBranch: true)

        let worktrees = try await service.listWorktrees(at: repoPath)
        XCTAssertEqual(worktrees.count, 1, "stale worktree metadata should be pruned")
        let branches = try await git(["branch", "--list", "stale"])
        XCTAssertTrue(branches.stdout.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
    }

    func testRemoveWorktreeRefusesMainWorktree() async throws {
        do {
            try await service.removeWorktree(at: repoPath, in: repoPath, branch: "main", deleteBranch: false)
            XCTFail("Expected cannotRemoveMainWorktree error")
        } catch GitServiceError.cannotRemoveMainWorktree(let url) {
            XCTAssertEqual(url.path, repoPath.path)
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: repoPath.path))
    }

    func testRemoveWorktreeRefusesRootAndAncestorPaths() async throws {
        let root = URL(fileURLWithPath: "/")
        do {
            try await service.removeWorktree(at: root, in: repoPath, branch: "main", deleteBranch: false)
            XCTFail("Expected invalidWorktreePath error")
        } catch GitServiceError.invalidWorktreePath(let url) {
            XCTAssertEqual(url.path, root.path)
        }

        let ancestor = repoPath.deletingLastPathComponent()
        do {
            try await service.removeWorktree(at: ancestor, in: repoPath, branch: "main", deleteBranch: false)
            XCTFail("Expected cannotRemoveMainWorktree error")
        } catch GitServiceError.cannotRemoveMainWorktree(let url) {
            XCTAssertEqual(url.path, ancestor.path)
        }
    }

    func testRemoveWorktreeRefusesUnownedDirectory() async throws {
        let unowned = worktreeBase.appendingPathComponent("unowned-folder")
        try FileManager.default.createDirectory(at: unowned, withIntermediateDirectories: true)
        XCTAssertTrue(FileManager.default.fileExists(atPath: unowned.path))

        do {
            try await service.removeWorktree(at: unowned, in: repoPath, branch: "unowned", deleteBranch: false)
            XCTFail("Expected notAWorktree error")
        } catch GitServiceError.notAWorktree(let url) {
            XCTAssertEqual(url.path, unowned.path)
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: unowned.path))
        try? FileManager.default.removeItem(at: unowned)
    }

    // MARK: - Write path (stage / unstage / discard / commit / push / fetch)

    func testStageUnstageDiscardAndCommit() async throws {
        try "changed\n".write(to: repoPath.appendingPathComponent("README.md"), atomically: true, encoding: .utf8)
        try await service.stage(paths: ["README.md"], at: repoPath)
        let stagedStatus = try await service.status(at: repoPath)
        XCTAssertEqual(stagedStatus.entries.first?.indexStatus, "M")

        try await service.unstage(paths: ["README.md"], at: repoPath)
        let unstaged = try await service.status(at: repoPath)
        XCTAssertEqual(unstaged.entries.first?.indexStatus, " ")
        XCTAssertEqual(unstaged.entries.first?.worktreeStatus, "M")

        try await service.discard(paths: ["README.md"], at: repoPath)
        XCTAssertEqual(
            try String(contentsOf: repoPath.appendingPathComponent("README.md"), encoding: .utf8),
            "hello\n"
        )

        let newFile = repoPath.appendingPathComponent("NEW.md")
        try "new\n".write(to: newFile, atomically: true, encoding: .utf8)
        try await service.discard(paths: ["NEW.md"], at: repoPath)
        XCTAssertFalse(FileManager.default.fileExists(atPath: newFile.path))

        try "changed\n".write(to: repoPath.appendingPathComponent("README.md"), atomically: true, encoding: .utf8)
        try await service.stage(paths: ["README.md"], at: repoPath)
        try await service.commit(message: "Update README", at: repoPath)
        let afterCommit = try await service.changes(at: repoPath)
        XCTAssertTrue(afterCommit.staged.isEmpty)
        let log = try await git(["log", "-1", "--format=%s"])
        XCTAssertEqual(log.stdout.trimmingCharacters(in: .whitespacesAndNewlines), "Update README")

        do {
            try await service.commit(message: "empty", at: repoPath)
            XCTFail("expected nothingToCommit error")
        } catch GitServiceError.nothingToCommit {
            // expected
        }
    }

    func testPushFetchAndMissingRemote() async throws {
        do {
            try await service.push(branch: "main", at: repoPath)
            XCTFail("expected noRemoteConfigured error")
        } catch GitServiceError.noRemoteConfigured {
            // expected
        }

        let remotePath = worktreeBase.appendingPathComponent("origin.git")
        try await runner.run(
            ["git", "init", "--bare", remotePath.path],
            executable: URL(fileURLWithPath: "/usr/bin/env"),
            workingDirectory: worktreeBase
        )
        try await git(["remote", "add", "origin", remotePath.path])

        try await service.push(branch: "main", at: repoPath)
        let upstream = try await git(["rev-parse", "--abbrev-ref", "--symbolic-full-name", "@{u}"])
        XCTAssertEqual(upstream.stdout.trimmingCharacters(in: .whitespacesAndNewlines), "origin/main")

        try "more\n".write(to: repoPath.appendingPathComponent("README.md"), atomically: true, encoding: .utf8)
        try await service.stage(paths: ["README.md"], at: repoPath)
        try await service.commit(message: "second commit", at: repoPath)
        try await service.push(branch: "main", at: repoPath)
        try await service.fetch(at: repoPath)
    }

    // MARK: - Commit history

    /// Commits with a deterministic identity, since `setUp`'s seed commit uses
    /// the ambient git config and these assert on author fields.
    @discardableResult
    private func commit(_ message: String) async throws -> CommandResult {
        try await git(["-c", "user.name=Flotilla Tests", "-c", "user.email=flotilla-tests@example.com",
                       "commit", "-m", message])
    }

    func testLogReturnsCommitsNewestFirstWithStats() async throws {
        try "one\ntwo\n".write(to: repoPath.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
        try await git(["add", "a.txt"])
        try await commit("feat: add a")

        let commits = try await service.log(at: repoPath, ref: nil, skip: 0, maxCount: 100)

        XCTAssertEqual(commits.map(\.subject), ["feat: add a", "init"])
        XCTAssertEqual(commits.first?.stat, GitDiffStat(files: 1, additions: 2, deletions: 0))
        XCTAssertEqual(commits.first?.changedFileCount, 1)
        XCTAssertEqual(commits.first?.authorName, "Flotilla Tests")
        XCTAssertEqual(commits.first?.authorEmail, "flotilla-tests@example.com")
    }

    func testLogDecoratesHeadAndBranchWithoutMisreadingSlashedBranch() async throws {
        try await git(["checkout", "-b", "fix/slashed-name"])

        let commits = try await service.log(at: repoPath, ref: nil, skip: 0, maxCount: 1)
        let refs = try XCTUnwrap(commits.first?.refs)

        XCTAssertTrue(refs.contains(GitCommitRef(name: "HEAD", kind: .head)))
        XCTAssertTrue(
            refs.contains(GitCommitRef(name: "fix/slashed-name", kind: .localBranch)),
            "a local branch containing a slash must not be classified as remote"
        )
    }

    func testLogPagesWithSkipAndMaxCount() async throws {
        for index in 1...4 {
            try "\(index)\n".write(to: repoPath.appendingPathComponent("p\(index).txt"), atomically: true, encoding: .utf8)
            try await git(["add", "."])
            try await commit("commit \(index)")
        }

        let firstPage = try await service.log(at: repoPath, ref: nil, skip: 0, maxCount: 2)
        let secondPage = try await service.log(at: repoPath, ref: nil, skip: 2, maxCount: 2)

        XCTAssertEqual(firstPage.map(\.subject), ["commit 4", "commit 3"])
        XCTAssertEqual(secondPage.map(\.subject), ["commit 2", "commit 1"])
        XCTAssertTrue(Set(firstPage.map(\.sha)).isDisjoint(with: Set(secondPage.map(\.sha))))
    }

    func testLogOnRepositoryWithNoCommitsReturnsEmptyRatherThanThrowing() async throws {
        let empty = worktreeBase.appendingPathComponent("empty-repo")
        try FileManager.default.createDirectory(at: empty, withIntermediateDirectories: true)
        try await runner.run(["git", "init", "-b", "main", empty.path], executable: URL(fileURLWithPath: "/usr/bin/env"), workingDirectory: worktreeBase)

        let commits = try await service.log(at: empty, ref: nil, skip: 0, maxCount: 10)
        XCTAssertEqual(commits, [])
    }

    func testLogRecordsMergeWithTwoParents() async throws {
        try await git(["checkout", "-b", "feat"])
        try "feature\n".write(to: repoPath.appendingPathComponent("b.txt"), atomically: true, encoding: .utf8)
        try await git(["add", "."])
        try await commit("feat: add b")
        try await git(["checkout", "main"])
        try "main side\n".write(to: repoPath.appendingPathComponent("c.txt"), atomically: true, encoding: .utf8)
        try await git(["add", "."])
        try await commit("main: add c")
        try await git(["-c", "user.name=Flotilla Tests", "-c", "user.email=flotilla-tests@example.com",
                       "merge", "--no-ff", "feat", "-m", "Merge branch 'feat'"])

        let head = try await service.log(at: repoPath, ref: nil, skip: 0, maxCount: 1).first
        let merge = try XCTUnwrap(head)

        XCTAssertTrue(merge.isMerge)
        XCTAssertEqual(merge.parents.count, 2)
        XCTAssertEqual(merge.stat, GitDiffStat(additions: 0, deletions: 0), "git log emits no numstat for merges")
    }

    func testCommitDetailReportsFileKindsAndHunks() async throws {
        try "first\nsecond\n".write(to: repoPath.appendingPathComponent("keep.txt"), atomically: true, encoding: .utf8)
        try "doomed\n".write(to: repoPath.appendingPathComponent("doomed.txt"), atomically: true, encoding: .utf8)
        try await git(["add", "."])
        try await commit("setup")

        try "first\nsecond changed\n".write(to: repoPath.appendingPathComponent("keep.txt"), atomically: true, encoding: .utf8)
        try FileManager.default.removeItem(at: repoPath.appendingPathComponent("doomed.txt"))
        try "brand new\n".write(to: repoPath.appendingPathComponent("fresh.txt"), atomically: true, encoding: .utf8)
        try await git(["add", "-A"])
        try await commit("mixed change")

        let latest = try await service.log(at: repoPath, ref: nil, skip: 0, maxCount: 1).first
        let head = try XCTUnwrap(latest)
        let detail = try await service.commitDetail(sha: head.sha, at: repoPath)

        let byPath = Dictionary(uniqueKeysWithValues: detail.files.map { ($0.path, $0) })
        XCTAssertEqual(byPath["keep.txt"]?.kind, .modified)
        XCTAssertEqual(byPath["doomed.txt"]?.kind, .deleted)
        XCTAssertEqual(byPath["fresh.txt"]?.kind, .added)
        XCTAssertFalse(byPath["keep.txt"]?.hunks.isEmpty ?? true, "a modified file must carry its hunks")
        XCTAssertEqual(detail.stat.additions, 2, "one changed line plus one new line")
    }

    /// numstat fuses a rename into `old => new`, which is why per-file counts
    /// are derived from the patch instead.
    func testCommitDetailTracksRenames() async throws {
        try await git(["mv", "README.md", "READTHIS.md"])
        try await commit("chore: rename readme")

        let latest = try await service.log(at: repoPath, ref: nil, skip: 0, maxCount: 1).first
        let head = try XCTUnwrap(latest)
        let detail = try await service.commitDetail(sha: head.sha, at: repoPath)

        XCTAssertEqual(detail.files.count, 1)
        XCTAssertEqual(detail.files.first?.kind, .renamed)
        XCTAssertEqual(detail.files.first?.path, "READTHIS.md")
        XCTAssertEqual(detail.files.first?.previousPath, "README.md")
    }

    func testUnpushedSHAsIsEmptyWithoutUpstreamAndListsLocalOnlyCommitsWithOne() async throws {
        // No upstream configured yet — "no upstream" is normal, not an error.
        let withoutUpstream = try await service.unpushedSHAs(at: repoPath, ref: nil)
        XCTAssertEqual(withoutUpstream, [])

        let remotePath = worktreeBase.appendingPathComponent("origin-unpushed.git")
        try await runner.run(["git", "init", "--bare", remotePath.path], executable: URL(fileURLWithPath: "/usr/bin/env"), workingDirectory: worktreeBase)
        try await git(["remote", "add", "origin", remotePath.path])
        try await service.push(branch: "main", at: repoPath)
        let afterPush = try await service.unpushedSHAs(at: repoPath, ref: nil)
        XCTAssertEqual(afterPush, [], "everything is pushed")

        try "local only\n".write(to: repoPath.appendingPathComponent("local.txt"), atomically: true, encoding: .utf8)
        try await git(["add", "."])
        try await commit("local: not pushed yet")
        let latest = try await service.log(at: repoPath, ref: nil, skip: 0, maxCount: 1).first
        let head = try XCTUnwrap(latest)

        let unpushed = try await service.unpushedSHAs(at: repoPath, ref: nil)
        XCTAssertEqual(unpushed, [head.sha])
    }

    func testCommitsOnBranchReturnsOnlyThatBranchesOwnCommits() async throws {
        try await git(["checkout", "-b", "feat/agent-work"])
        try "agent\n".write(to: repoPath.appendingPathComponent("agent.txt"), atomically: true, encoding: .utf8)
        try await git(["add", "."])
        try await commit("agent: first")
        try "more\n".write(to: repoPath.appendingPathComponent("agent2.txt"), atomically: true, encoding: .utf8)
        try await git(["add", "."])
        try await commit("agent: second")

        let branchCommits = try await service.log(at: repoPath, ref: "feat/agent-work", skip: 0, maxCount: 10)
        let owned = try await service.commitsOnBranch("feat/agent-work", notOn: "main", at: repoPath)

        XCTAssertEqual(owned.count, 2)
        XCTAssertTrue(owned.contains(branchCommits[0].sha))
        XCTAssertTrue(owned.contains(branchCommits[1].sha))
        // The seed commit is shared with main, so it is not the branch's own.
        XCTAssertFalse(owned.contains(branchCommits[2].sha))
    }

    func testCommitsOnBranchIsEmptyForUnknownRefsOrSelfComparison() async throws {
        let unknown = try await service.commitsOnBranch("does-not-exist", notOn: "main", at: repoPath)
        XCTAssertEqual(unknown, [], "a pruned session branch must not surface as an error")

        let same = try await service.commitsOnBranch("main", notOn: "main", at: repoPath)
        XCTAssertEqual(same, [])
    }

    func testRemoteURLIsNilWithoutOriginAndResolvesWithOne() async throws {
        let withoutOrigin = try await service.remoteURL(at: repoPath)
        XCTAssertNil(withoutOrigin)

        try await git(["remote", "add", "origin", "git@github.com:Niclassslua/Flotilla.git"])
        let withOrigin = try await service.remoteURL(at: repoPath)
        XCTAssertEqual(withOrigin, "git@github.com:Niclassslua/Flotilla.git")
    }

    func testUnquotePathHandlesOctalAndEscapedCharacters() {
        // Plain string without quotes is unchanged
        XCTAssertEqual(GitService.unquotePath("simple/path.txt"), "simple/path.txt")

        // Escaped quotes and spaces
        XCTAssertEqual(GitService.unquotePath("\"path with \\\"quotes\\\" and spaces.txt\""), "path with \"quotes\" and spaces.txt")

        // Standard escapes
        XCTAssertEqual(GitService.unquotePath("\"folder\\tname/file\\n.txt\""), "folder\tname/file\n.txt")

        // Octal escape sequences for UTF-8 bytes (e.g. \342\234\223 is ✓)
        XCTAssertEqual(GitService.unquotePath("\"\\342\\234\\223.txt\""), "✓.txt")

        // German umlauts (\303\244 = ä, \303\266 = ö)
        XCTAssertEqual(GitService.unquotePath("\"m\\303\\244rz/sch\\303\\266n.txt\""), "märz/schön.txt")
    }

    func testParseUnifiedDiffWithQuotedAndNonASCIIPaths() {
        let diff = """
        diff --git "a/path with space.txt" "b/path with space.txt"
        index 0000000..1111111 100644
        --- "a/path with space.txt"
        +++ "b/path with space.txt"
        @@ -0,0 +1,1 @@
        +hello
        diff --git "a/\\342\\234\\223.txt" "b/\\342\\234\\223.txt"
        index 0000000..2222222 100644
        --- "a/\\342\\234\\223.txt"
        +++ "b/\\342\\234\\223.txt"
        @@ -0,0 +1,1 @@
        +checkmark
        """
        let parsed = GitService.parseUnifiedDiff(diff)
        XCTAssertEqual(parsed.count, 2)
        XCTAssertEqual(parsed[0].path, "path with space.txt")
        XCTAssertEqual(parsed[1].path, "✓.txt")
    }

    func testStatusWithNonASCIIAndSpacedFilenames() async throws {
        let spaced = repoPath.appendingPathComponent("a file with spaces.txt")
        let nonASCII = repoPath.appendingPathComponent("✓_check.txt")
        try "content1\n".write(to: spaced, atomically: true, encoding: .utf8)
        try "content2\n".write(to: nonASCII, atomically: true, encoding: .utf8)

        let status = try await service.status(at: repoPath)
        let paths = Set(status.entries.map(\.path))
        XCTAssertTrue(paths.contains("a file with spaces.txt"))
        XCTAssertTrue(paths.contains("✓_check.txt"))
    }
}


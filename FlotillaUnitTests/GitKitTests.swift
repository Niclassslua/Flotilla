import XCTest
import GitKit

/// Crafted multi-file/multi-hunk input, exercised directly rather than
/// only through a real git repo — precise edge cases (multiple hunks in
/// one file, multiple files in one diff) are much easier to set up this way.
final class UnifiedDiffParsingTests: XCTestCase {
    func testParsesMultipleHunksAcrossMultipleFiles() {
        let raw = """
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

        let diffs = GitService.parseUnifiedDiff(raw)

        XCTAssertEqual(diffs.count, 2)

        let file1 = diffs[0]
        XCTAssertEqual(file1.path, "file1.txt")
        XCTAssertEqual(file1.hunks.count, 2)
        XCTAssertEqual(file1.hunks[0].header, "@@ -1,3 +1,4 @@")
        XCTAssertEqual(file1.hunks[0].lines, [" line1", "-line2", "+line2 modified", "+line2b", " line3"])
        XCTAssertEqual(file1.hunks[1].header, "@@ -10,2 +11,2 @@")
        XCTAssertEqual(file1.hunks[1].lines, ["-old10", "+new10", " line11"])

        let file2 = diffs[1]
        XCTAssertEqual(file2.path, "file2.txt")
        XCTAssertEqual(file2.hunks.count, 1)
        XCTAssertEqual(file2.hunks[0].lines, ["-hello", "+world"])
    }

    func testEmptyDiffProducesNoFiles() {
        XCTAssertTrue(GitService.parseUnifiedDiff("").isEmpty)
    }

    func testDeletedFileKeepsOriginalPathInsteadOfDevNull() {
        let raw = """
        diff --git a/obsolete.swift b/obsolete.swift
        deleted file mode 100644
        index 1234567..0000000
        --- a/obsolete.swift
        +++ /dev/null
        @@ -1 +0,0 @@
        -let obsolete = true
        """

        let diff = GitService.parseUnifiedDiff(raw).first
        XCTAssertEqual(diff?.path, "obsolete.swift")
        XCTAssertEqual(diff?.hunks.first?.lines, ["-let obsolete = true"])
    }
}

final class NumstatParsingTests: XCTestCase {
    func testSumsMultipleFiles() {
        let raw = "10\t2\tfile1.swift\n3\t0\tfile2.swift\n"
        XCTAssertEqual(GitService.parseNumstat(raw), GitDiffStat(additions: 13, deletions: 2))
    }

    func testBinaryFilesContributeZero() {
        let raw = "-\t-\timage.png\n5\t1\tcode.swift\n"
        XCTAssertEqual(GitService.parseNumstat(raw), GitDiffStat(additions: 5, deletions: 1))
    }

    func testEmptyInputIsZero() {
        XCTAssertEqual(GitService.parseNumstat(""), GitDiffStat(additions: 0, deletions: 0))
    }
}

final class WorktreePlannerTests: XCTestCase {
    func testMainCheckoutDecision() {
        let planner = WorktreePlanner()
        let root = URL(fileURLWithPath: "/Users/dev/MyProject")
        let decision = planner.plan(
            useNewWorktree: false,
            projectRoot: root,
            worktreeBaseDirectory: URL(fileURLWithPath: "/Users/dev/.flotilla/worktrees"),
            branchName: "flotilla/ignored"
        )
        XCTAssertEqual(decision, .useExistingCheckout(path: root))
    }

    func testNewWorktreeDecision() {
        let planner = WorktreePlanner()
        let root = URL(fileURLWithPath: "/Users/dev/MyProject")
        let base = URL(fileURLWithPath: "/Users/dev/.flotilla/worktrees")
        let decision = planner.plan(
            useNewWorktree: true,
            projectRoot: root,
            worktreeBaseDirectory: base,
            branchName: "flotilla/fix-login"
        )
        XCTAssertEqual(decision, .createWorktree(
            basePath: root,
            branch: "flotilla/fix-login",
            destination: base.appendingPathComponent("flotilla/fix-login", isDirectory: true)
        ))
    }
}

final class MockGitServiceTests: XCTestCase {
    func testRecordsWorktreeCallsAndReturnsConfiguredValues() async throws {
        let mock = MockGitService()
        mock.branchToReturn = "develop"

        let branch = try await mock.currentBranch(at: URL(fileURLWithPath: "/tmp"))
        XCTAssertEqual(branch, "develop")

        _ = try await mock.createWorktree(
            basePath: URL(fileURLWithPath: "/repo"),
            branch: "feature-x",
            destination: URL(fileURLWithPath: "/repo/../wt/feature-x")
        )
        XCTAssertEqual(mock.createWorktreeCalls.count, 1)
        XCTAssertEqual(mock.createWorktreeCalls.first?.branch, "feature-x")
    }

    func testThrowsConfiguredError() async {
        let mock = MockGitService()
        mock.errorToThrow = GitServiceError.commandFailed(exitCode: 1, stderr: "boom")

        do {
            _ = try await mock.status(at: URL(fileURLWithPath: "/tmp"))
            XCTFail("expected error to propagate")
        } catch {
            XCTAssertEqual(error as? GitServiceError, .commandFailed(exitCode: 1, stderr: "boom"))
        }
    }

    func testRecordsWriteCalls() async throws {
        let mock = MockGitService()
        let repoPath = URL(fileURLWithPath: "/repo")

        try await mock.stage(paths: ["a.swift"], at: repoPath)
        try await mock.unstage(paths: ["b.swift"], at: repoPath)
        try await mock.discard(paths: ["c.swift"], at: repoPath)
        try await mock.commit(message: "msg", at: repoPath)
        try await mock.push(branch: "main", at: repoPath)
        try await mock.fetch(at: repoPath)

        XCTAssertEqual(mock.stageCalls.first?.paths, ["a.swift"])
        XCTAssertEqual(mock.unstageCalls.first?.paths, ["b.swift"])
        XCTAssertEqual(mock.discardCalls.first?.paths, ["c.swift"])
        XCTAssertEqual(mock.commitCalls.first?.message, "msg")
        XCTAssertEqual(mock.pushCalls.first?.branch, "main")
        XCTAssertEqual(mock.fetchCalls.first, repoPath)
    }
}

final class MockGhServiceTests: XCTestCase {
    func testRecordsCallAndReturnsConfiguredURL() async throws {
        let mock = MockGhService()
        mock.urlToReturn = URL(string: "https://github.com/example/example/pull/42")!

        let url = try await mock.createPullRequest(title: "Add feature", body: "Body", base: "main", at: URL(fileURLWithPath: "/repo"))

        XCTAssertEqual(url.absoluteString, "https://github.com/example/example/pull/42")
        XCTAssertEqual(mock.createPullRequestCalls.first?.title, "Add feature")
        XCTAssertEqual(mock.createPullRequestCalls.first?.base, "main")
    }

    func testThrowsConfiguredError() async {
        let mock = MockGhService()
        mock.errorToThrow = GitServiceError.ghNotFound

        do {
            _ = try await mock.createPullRequest(title: "t", body: "b", base: nil, at: URL(fileURLWithPath: "/repo"))
            XCTFail("expected error to propagate")
        } catch {
            XCTAssertEqual(error as? GitServiceError, .ghNotFound)
        }
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

    func testCurrentBranch() async throws {
        let branch = try await service.currentBranch(at: repoPath)
        XCTAssertEqual(branch, "main")
    }

    func testStatusReportsUntrackedAndModifiedFiles() async throws {
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
        XCTAssertEqual(stat, GitDiffStat(additions: 6, deletions: 1))
    }

    func testDiffStatIsZeroForCleanTree() async throws {
        let stat = try await service.diffStat(at: repoPath)
        XCTAssertEqual(stat, GitDiffStat(additions: 0, deletions: 0))
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

    // MARK: - Write path (stage / unstage / discard / commit / push / fetch)

    func testStageMovesFileIntoIndex() async throws {
        try "changed\n".write(to: repoPath.appendingPathComponent("README.md"), atomically: true, encoding: .utf8)

        try await service.stage(paths: ["README.md"], at: repoPath)

        let status = try await service.status(at: repoPath)
        XCTAssertEqual(status.entries.first?.indexStatus, "M")
    }

    func testUnstageMovesFileBackOutOfIndex() async throws {
        try "changed\n".write(to: repoPath.appendingPathComponent("README.md"), atomically: true, encoding: .utf8)
        try await git(["add", "README.md"])

        try await service.unstage(paths: ["README.md"], at: repoPath)

        let status = try await service.status(at: repoPath)
        XCTAssertEqual(status.entries.first?.indexStatus, " ")
        XCTAssertEqual(status.entries.first?.worktreeStatus, "M")
    }

    func testDiscardRestoresTrackedFileContent() async throws {
        try "changed\n".write(to: repoPath.appendingPathComponent("README.md"), atomically: true, encoding: .utf8)

        try await service.discard(paths: ["README.md"], at: repoPath)

        let content = try String(contentsOf: repoPath.appendingPathComponent("README.md"), encoding: .utf8)
        XCTAssertEqual(content, "hello\n")
    }

    func testDiscardRemovesUntrackedFile() async throws {
        let newFile = repoPath.appendingPathComponent("NEW.md")
        try "new\n".write(to: newFile, atomically: true, encoding: .utf8)

        try await service.discard(paths: ["NEW.md"], at: repoPath)

        XCTAssertFalse(FileManager.default.fileExists(atPath: newFile.path))
    }

    func testCommitClearsStagedChanges() async throws {
        try "changed\n".write(to: repoPath.appendingPathComponent("README.md"), atomically: true, encoding: .utf8)
        try await service.stage(paths: ["README.md"], at: repoPath)

        try await service.commit(message: "Update README", at: repoPath)

        let snapshot = try await service.changes(at: repoPath)
        XCTAssertTrue(snapshot.staged.isEmpty)
        let log = try await git(["log", "-1", "--format=%s"])
        XCTAssertEqual(log.stdout.trimmingCharacters(in: .whitespacesAndNewlines), "Update README")
    }

    func testCommitWithNothingStagedThrowsNothingToCommit() async throws {
        do {
            try await service.commit(message: "empty", at: repoPath)
            XCTFail("expected nothingToCommit error")
        } catch GitServiceError.nothingToCommit {
            // expected
        }
    }

    func testPushSetsUpstreamOnFirstPushAndSucceedsOnSecond() async throws {
        let remotePath = worktreeBase.appendingPathComponent("origin.git")
        try await runner.run(["git", "init", "--bare", remotePath.path], executable: URL(fileURLWithPath: "/usr/bin/env"), workingDirectory: worktreeBase)
        try await git(["remote", "add", "origin", remotePath.path])

        try await service.push(branch: "main", at: repoPath)

        let upstream = try await git(["rev-parse", "--abbrev-ref", "--symbolic-full-name", "@{u}"])
        XCTAssertEqual(upstream.stdout.trimmingCharacters(in: .whitespacesAndNewlines), "origin/main")

        // Second push, upstream already configured, should still succeed.
        try "more\n".write(to: repoPath.appendingPathComponent("README.md"), atomically: true, encoding: .utf8)
        try await service.stage(paths: ["README.md"], at: repoPath)
        try await service.commit(message: "second commit", at: repoPath)
        try await service.push(branch: "main", at: repoPath)
    }

    func testPushWithNoRemoteThrowsNoRemoteConfigured() async throws {
        do {
            try await service.push(branch: "main", at: repoPath)
            XCTFail("expected noRemoteConfigured error")
        } catch GitServiceError.noRemoteConfigured {
            // expected
        }
    }

    func testFetchSucceedsAgainstConfiguredRemote() async throws {
        let remotePath = worktreeBase.appendingPathComponent("origin-fetch.git")
        try await runner.run(["git", "init", "--bare", remotePath.path], executable: URL(fileURLWithPath: "/usr/bin/env"), workingDirectory: worktreeBase)
        try await git(["remote", "add", "origin", remotePath.path])
        try await service.push(branch: "main", at: repoPath)

        try await service.fetch(at: repoPath)
    }
}

final class ProcessCommandRunnerTests: XCTestCase {
    func testDrainsLargeOutputWithoutPipeDeadlock() async throws {
        let result = try await ProcessCommandRunner().run(
            ["1", "100000"],
            executable: URL(fileURLWithPath: "/usr/bin/seq"),
            workingDirectory: URL(fileURLWithPath: "/tmp")
        )

        XCTAssertEqual(result.exitCode, 0)
        XCTAssertTrue(result.stdout.hasPrefix("1\n2\n3\n"))
        XCTAssertTrue(result.stdout.hasSuffix("100000\n"))
        XCTAssertGreaterThan(result.stdout.utf8.count, 500_000)
    }

    func testInheritsParentEnvironmentForPathLookups() async throws {
        let result = try await ProcessCommandRunner().run(
            ["-c", "echo $HOME"],
            executable: URL(fileURLWithPath: "/bin/sh"),
            workingDirectory: URL(fileURLWithPath: "/tmp")
        )
        XCTAssertFalse(result.stdout.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, "HOME should be inherited from the parent process")
    }

    func testTimeoutCancelsHungProcessAndThrows() async throws {
        do {
            _ = try await ProcessCommandRunner(timeout: 0.2).run(
                ["100"],
                executable: URL(fileURLWithPath: "/bin/sleep"),
                workingDirectory: URL(fileURLWithPath: "/tmp")
            )
            XCTFail("expected a timeout error")
        } catch let error as CommandTimeoutError {
            XCTAssertEqual(error.seconds, 0.2)
        }
    }
}

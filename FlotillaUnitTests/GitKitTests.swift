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

    func testSingleFileSingleHunk() {
        let raw = """
        diff --git a/README.md b/README.md
        index 111..222 100644
        --- a/README.md
        +++ b/README.md
        @@ -1,1 +1,2 @@
         # Title
        +New line
        """
        let diffs = GitService.parseUnifiedDiff(raw)
        XCTAssertEqual(diffs.count, 1)
        XCTAssertEqual(diffs[0].path, "README.md")
        XCTAssertEqual(diffs[0].hunks.count, 1)
        XCTAssertEqual(diffs[0].hunks[0].lines, [" # Title", "+New line"])
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

    func testDiffDistinguishesStagedFromUnstaged() async throws {
        try "changed\n".write(to: repoPath.appendingPathComponent("README.md"), atomically: true, encoding: .utf8)

        let unstagedBefore = try await service.diff(at: repoPath, staged: false)
        XCTAssertEqual(unstagedBefore.first?.path, "README.md")

        let stagedBefore = try await service.diff(at: repoPath, staged: true)
        XCTAssertTrue(stagedBefore.isEmpty)

        try await git(["add", "README.md"])

        let stagedAfter = try await service.diff(at: repoPath, staged: true)
        XCTAssertEqual(stagedAfter.first?.path, "README.md")
        XCTAssertFalse(stagedAfter.first?.hunks.isEmpty ?? true)
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
}

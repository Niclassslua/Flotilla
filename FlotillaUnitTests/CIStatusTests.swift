import XCTest
import SessionKit
import GitKit
import ProcessKit
@testable import Flotilla

/// CI status: decoding what `gh` prints, choosing between a branch's PR and
/// its bare Actions runs, and deciding when a failure is news.
final class GhJSONTests: XCTestCase {
    /// Shaped like real `gh pr view --json …,statusCheckRollup` output: Actions
    /// check runs, a re-run of one of them, and an external status context.
    private let prView = #"""
    {
      "number": 142,
      "url": "https://github.com/acme/app/pull/142",
      "state": "OPEN",
      "isDraft": false,
      "reviewDecision": "REVIEW_REQUIRED",
      "statusCheckRollup": [
        {"__typename": "CheckRun", "name": "build", "workflowName": "Build", "status": "COMPLETED", "conclusion": "SUCCESS",
         "detailsUrl": "https://github.com/acme/app/actions/runs/111/job/1", "startedAt": "2026-10-01T10:00:00Z", "completedAt": "2026-10-01T10:05:00Z"},
        {"__typename": "CheckRun", "name": "unit tests", "workflowName": "Build", "status": "COMPLETED", "conclusion": "FAILURE",
         "detailsUrl": "https://github.com/acme/app/actions/runs/111/job/2", "startedAt": "2026-10-01T10:00:00Z", "completedAt": "2026-10-01T10:04:00Z"},
        {"__typename": "CheckRun", "name": "lint", "workflowName": "Build", "status": "COMPLETED", "conclusion": "FAILURE",
         "detailsUrl": "https://github.com/acme/app/actions/runs/100/job/9", "startedAt": "2026-10-01T09:00:00Z", "completedAt": "2026-10-01T09:01:00Z"},
        {"__typename": "CheckRun", "name": "lint", "workflowName": "Build", "status": "COMPLETED", "conclusion": "SUCCESS",
         "detailsUrl": "https://github.com/acme/app/actions/runs/111/job/3", "startedAt": "2026-10-01T10:00:00Z", "completedAt": "2026-10-01T10:01:00Z"},
        {"__typename": "CheckRun", "name": "docs", "workflowName": "Build", "status": "COMPLETED", "conclusion": "CANCELLED",
         "detailsUrl": "https://github.com/acme/app/actions/runs/111/job/4", "startedAt": "2026-10-01T10:00:00Z", "completedAt": "0001-01-01T00:00:00Z"},
        {"__typename": "StatusContext", "context": "ci/circleci", "state": "PENDING",
         "targetUrl": "https://circleci.com/gh/acme/app/77", "startedAt": "2026-10-01T10:00:00Z"}
      ]
    }
    """#

    func testPullRequestRollupDecodesChecksAndKeepsOnlyTheLatestRerun() throws {
        let status = try GhJSON.pullRequestStatus(from: Data(prView.utf8))

        XCTAssertEqual(status.pullRequest?.number, 142)
        XCTAssertEqual(status.pullRequest?.state, .open)
        XCTAssertEqual(status.pullRequest?.reviewDecision, "REVIEW_REQUIRED")
        XCTAssertEqual(status.checks.map(\.name), ["build", "unit tests", "lint", "docs", "ci/circleci"])

        let byName = Dictionary(uniqueKeysWithValues: status.checks.map { ($0.name, $0) })
        XCTAssertEqual(byName["lint"]?.state, .passing, "a passing re-run replaces the earlier failure")
        XCTAssertEqual(byName["unit tests"]?.runID, 111, "the run ID comes from the details URL, for --log-failed")
        XCTAssertEqual(byName["docs"]?.state, .skipped, "cancelled says nothing about the code")
        XCTAssertNil(byName["docs"]?.completedAt, "GitHub's zero date means not finished")
        XCTAssertEqual(byName["ci/circleci"]?.state, .pending)
        XCTAssertNil(byName["ci/circleci"]?.runID, "external contexts have no Actions log")

        XCTAssertEqual(status.state, .failing, "one red check makes the branch red even while others run")
        XCTAssertEqual(status.failingChecks.map(\.name), ["unit tests"])
    }

    func testRunListUsesOnlyTheNewestCommit() throws {
        let runs = #"""
        [
          {"databaseId": 3, "workflowName": "Build", "status": "in_progress", "conclusion": "", "url": "https://github.com/acme/app/actions/runs/3",
           "headSha": "bbb", "createdAt": "2026-10-01T10:00:00Z", "updatedAt": "2026-10-01T10:01:00Z"},
          {"databaseId": 2, "workflowName": "Lint", "status": "completed", "conclusion": "success", "url": "https://github.com/acme/app/actions/runs/2",
           "headSha": "bbb", "createdAt": "2026-10-01T10:00:00Z", "updatedAt": "2026-10-01T10:00:30Z"},
          {"databaseId": 1, "workflowName": "Build", "status": "completed", "conclusion": "failure", "url": "https://github.com/acme/app/actions/runs/1",
           "headSha": "aaa", "createdAt": "2026-09-30T10:00:00Z", "updatedAt": "2026-09-30T10:05:00Z"}
        ]
        """#
        let checks = try GhJSON.workflowRunChecks(from: Data(runs.utf8))

        XCTAssertEqual(checks.map(\.name), ["Build", "Lint"], "the old commit's failure is history, not the branch's state")
        XCTAssertEqual(checks.first?.state, .pending)
        XCTAssertEqual(checks.first?.runID, 3)
        XCTAssertEqual(CIStatus(checks: checks).state, .pending)
        XCTAssertTrue(try GhJSON.workflowRunChecks(from: Data("[]".utf8)).isEmpty)
    }

    func testLogTailKeepsTheEndWithinBothBounds() {
        let log = (1...500).map { "line \($0)" }.joined(separator: "\n")
        let tail = GhJSON.logTail(log, maxLines: 150, maxBytes: 600)

        XCTAssertTrue(tail.hasSuffix("line 500"), "the error is at the end")
        XCTAssertLessThanOrEqual(tail.utf8.count, 600)
        XCTAssertFalse(tail.contains("line 1\n"))
    }
}

/// `GhService` reads a PR's checks when there is one and falls back to runs
/// only for the specific "no PR" answer — never to mask auth or network errors.
final class GhServiceCITests: XCTestCase {
    private final class ScriptedRunner: CommandRunning, @unchecked Sendable {
        var results: [String: CommandResult] = [:]
        private(set) var calls: [[String]] = []
        private(set) var executables: [URL] = []
        func run(_ arguments: [String], executable: URL, workingDirectory: URL) async throws -> CommandResult {
            calls.append(arguments)
            executables.append(executable)
            return results[arguments[0] + " " + arguments[1]] ?? CommandResult(exitCode: 1, stdout: "", stderr: "unexpected")
        }
    }

    private let repo = URL(fileURLWithPath: "/tmp/repo")
    private let gh = URL(fileURLWithPath: "/usr/local/bin/gh")

    func testBranchWithoutPullRequestFallsBackToWorkflowRunsForHeadCommit() async throws {
        let runner = ScriptedRunner()
        runner.results["pr view"] = CommandResult(exitCode: 1, stdout: "", stderr: "no pull requests found for branch \"feature\"")
        runner.results["rev-parse HEAD"] = CommandResult(exitCode: 0, stdout: "abc\n", stderr: "")
        runner.results["run list"] = CommandResult(exitCode: 0, stdout: #"[{"databaseId": 9, "workflowName": "Build", "status": "completed", "conclusion": "failure", "url": "https://x/9", "headSha": "abc"}]"#, stderr: "")

        let status = try await GhService(ghExecutable: gh, runner: runner).ciStatus(forBranch: "feature", at: repo)

        XCTAssertNil(status?.pullRequest)
        XCTAssertEqual(status?.state, .failing)
        XCTAssertEqual(
            runner.calls.map { $0.prefix(3).joined(separator: " ") },
            ["pr view feature", "rev-parse HEAD", "run list --commit"]
        )
        XCTAssertEqual(runner.calls[2][3], "abc", "runs are keyed by tip SHA, not the session branch name")
    }

    func testOtherGhFailuresAreReportedNotTreatedAsNoChecks() async {
        let runner = ScriptedRunner()
        runner.results["pr view"] = CommandResult(exitCode: 4, stdout: "", stderr: "To get started with GitHub CLI, please run: gh auth login")

        do {
            _ = try await GhService(ghExecutable: gh, runner: runner).ciStatus(forBranch: "feature", at: repo)
            XCTFail("an auth failure must surface")
        } catch {
            XCTAssertEqual(error as? GitServiceError, .ghCommandFailed(exitCode: 4, stderr: "To get started with GitHub CLI, please run: gh auth login"))
        }
        XCTAssertEqual(runner.calls.count, 1, "no fallback after a real failure")
    }
}

@MainActor
final class CIStatusStoreTests: XCTestCase {
    private func session(_ title: String, branch: String?, status: SessionStatus = .working) -> Session {
        Session(
            title: title,
            goal: "",
            agent: .claudeCode,
            projectID: UUID(),
            workingDirectory: URL(fileURLWithPath: "/tmp/\(title)"),
            worktree: branch.map { WorktreeInfo(branchName: $0, worktreePath: URL(fileURLWithPath: "/tmp/\(title)"), baseCheckoutPath: URL(fileURLWithPath: "/tmp/base")) },
            status: status
        )
    }

    private func status(_ state: CICheckState) -> CIStatus {
        CIStatus(checks: [CICheck(name: "unit tests", state: state, runID: 1)])
    }

    /// A user should hear about CI going red exactly once — not for a branch
    /// that was already red when Flotilla started, and not again on every poll.
    func testFailureNotifiesOnlyOnObservedTransition() async {
        let gh = MockGhService()
        let tracked = session("tracked", branch: "feature")
        let store = CIStatusStore(ghService: gh, sessions: { [tracked] })
        var notified: [String] = []
        store.onFailure = { session, check in notified.append("\(session.title):\(check.name)") }

        gh.ciStatusByBranch["feature"] = status(.pending)
        await store.refresh(sessionID: tracked.id)
        gh.ciStatusByBranch["feature"] = status(.failing)
        await store.refresh(sessionID: tracked.id)
        await store.refresh(sessionID: tracked.id)

        XCTAssertEqual(notified, ["tracked:unit tests"])
        XCTAssertEqual(store.failingSessionIDs, [tracked.id])

        let alreadyRed = session("already red", branch: "red")
        let coldStore = CIStatusStore(ghService: gh, sessions: { [alreadyRed] })
        coldStore.onFailure = { _, _ in notified.append("cold") }
        gh.ciStatusByBranch["red"] = status(.failing)
        await coldStore.refresh(sessionID: alreadyRed.id)
        XCTAssertFalse(notified.contains("cold"), "a failure present at first sight is not an event")
        XCTAssertEqual(coldStore.failingSessionIDs, [alreadyRed.id], "but it still counts as failing")
    }

    func testSessionsWithoutAWorktreeBranchAreNeverPolled() async {
        let gh = MockGhService()
        let mainCheckout = session("main checkout", branch: nil)
        let store = CIStatusStore(ghService: gh, sessions: { [mainCheckout] })

        await store.refresh(sessionID: mainCheckout.id)

        XCTAssertTrue(gh.ciStatusCalls.isEmpty, "the main checkout's CI belongs to the default branch, not this session")
    }

    /// Red CI is a reason to act: it outranks Ready for Review, and a session
    /// that is both waiting and red still counts once.
    func testFailingCIJoinsNeedsYouOnce() {
        let ready = session("ready", branch: "a", status: .readyForReview)
        let waiting = session("waiting", branch: "b", status: .waitingForInput)
        let calm = session("calm", branch: "c", status: .readyForReview)

        let attention = FleetAttention(sessions: [ready, waiting, calm], ciFailing: [ready.id, waiting.id])

        XCTAssertEqual(Set(attention.waiting.map(\.id)), [ready.id, waiting.id])
        XCTAssertEqual(attention.readyForReview.map(\.id), [calm.id])
        XCTAssertEqual(attention.dockBadgeLabel, "2")
    }
}

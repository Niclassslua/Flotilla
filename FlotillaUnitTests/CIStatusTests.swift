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

    /// Shaped like a real job log: thousands of passing lines, the failures
    /// well before the end, and post-job cleanup last.
    func testFailureExcerptFindsTheFailureNotTheCleanup() {
        var lines = (1...3000).map { "2026-11-04T20:10:00.0000000Z Test case 'Suite.test\($0)()' passed on 'My Mac' (0.001 seconds)" }
        lines[0] = "\u{FEFF}" + lines[0]
        lines.insert("2026-11-04T20:13:30.0000000Z Failing tests:", at: 1500)
        lines.insert("2026-11-04T20:13:30.0000000Z \tSuite.testBroken()", at: 1501)
        lines.insert("2026-11-04T20:13:31.0000000Z Test case 'Suite.testAlsoBroken()' failed on 'My Mac' (4.4 seconds)", at: 2800)
        lines.append("2026-11-04T20:13:31.0000000Z \u{1B}[31m##[error]Process completed with exit code 2.\u{1B}[0m")
        lines += (1...200).map { "2026-11-04T20:13:42.0000000Z [command]/opt/homebrew/bin/git config --local cleanup \($0)" }

        let excerpt = GhJSON.failureExcerpt(lines.joined(separator: "\n"), maxBytes: 4_000)

        XCTAssertTrue(excerpt.contains("Suite.testBroken()"))
        XCTAssertTrue(excerpt.contains("Suite.testAlsoBroken()"))
        XCTAssertTrue(excerpt.contains("##[error]Process completed"), "colour codes must not hide the error")
        XCTAssertFalse(excerpt.contains("2026-11-04T"), "timestamps only waste the budget")
        XCTAssertFalse(excerpt.contains("\u{1B}"))
        XCTAssertLessThanOrEqual(excerpt.utf8.count, 4_000)
    }

    func testPreSessionCommitsStopAtTheSessionsFirstCommit() {
        let reflog = "ddd\tcommit (amend): tidy\nccc\tcommit: mine\nbbb\tpull: Fast-forward\naaa\tbranch: Created from HEAD\n"
        XCTAssertEqual(GhJSON.preSessionCommits(fromReflog: reflog), ["aaa", "bbb"])
        XCTAssertEqual(GhJSON.preSessionCommits(fromReflog: "aaa\tbranch: Created from HEAD"), ["aaa"], "no commits yet")
        XCTAssertTrue(GhJSON.preSessionCommits(fromReflog: "").isEmpty, "an empty reflog hides nothing")
    }

    func testFailureExcerptFallsBackToTheTailWhenNothingLooksLikeAFailure() {
        let excerpt = GhJSON.failureExcerpt((1...500).map { "line \($0)" }.joined(separator: "\n"), maxBytes: 600)

        XCTAssertTrue(excerpt.hasSuffix("line 500"))
        XCTAssertLessThanOrEqual(excerpt.utf8.count, 600)
    }

    func testFailureExcerptKeepsAFailureLargerThanTheWholeBudget() {
        let log = (1...2000).map { "\($0): error: nope" }.joined(separator: "\n")

        XCTAssertFalse(GhJSON.failureExcerpt(log, maxBytes: 500).isEmpty)
    }

    func testJobIDAndCommitComeFromThePayload() throws {
        let json = #"{"number":1,"url":"https://github.com/a/b/pull/1","state":"OPEN","headRefOid":"abc","mergeStateStatus":"UNSTABLE","statusCheckRollup":[{"__typename":"CheckRun","name":"build","status":"COMPLETED","conclusion":"FAILURE","detailsUrl":"https://github.com/a/b/actions/runs/11/job/22"}]}"#
        let status = try GhJSON.pullRequestStatus(from: Data(json.utf8))

        XCTAssertEqual(status.commitSHA, "abc")
        XCTAssertEqual(status.pullRequest?.mergeStateStatus, "UNSTABLE")
        XCTAssertEqual(status.checks.first?.runID, 11)
        XCTAssertEqual(status.checks.first?.jobID, 22)
    }

    func testRunJobsBecomeChecksTheSameShapeAsARollup() throws {
        let json = #"{"jobs":[{"databaseId":7,"name":"unit tests","status":"completed","conclusion":"failure","url":"https://x/7","startedAt":"2026-10-01T10:00:00Z","completedAt":"2026-10-01T10:02:00Z"},{"databaseId":8,"name":"lint","status":"in_progress","conclusion":"","startedAt":"0001-01-01T00:00:00Z","completedAt":"0001-01-01T00:00:00Z"}]}"#
        let checks = try GhJSON.jobChecks(from: Data(json.utf8), workflowName: "Build", runID: 9)

        XCTAssertEqual(checks.map(\.name), ["unit tests", "lint"])
        XCTAssertEqual(checks.map(\.state), [.failing, .pending])
        XCTAssertEqual(checks.first?.jobID, 7)
        XCTAssertEqual(checks.first?.runID, 9)
        XCTAssertNil(checks.last?.startedAt, "GitHub's zero date means not started")
    }
}

/// The verdict is the first thing the Checks tab says; both workflows need
/// their own right answer.
final class CIVerdictTests: XCTestCase {
    private func check(_ state: CICheckState, required: Bool? = nil) -> CICheck {
        CICheck(name: UUID().uuidString, state: state, isRequired: required)
    }

    private func pr(_ state: GhPullRequest.State = .open, draft: Bool = false, review: String? = nil, merge: String? = nil) -> GhPullRequest {
        GhPullRequest(number: 1, url: URL(string: "https://x/1")!, state: state, isDraft: draft, reviewDecision: review, mergeStateStatus: merge)
    }

    private func verdict(_ pullRequest: GhPullRequest?, _ checks: [CICheck], tip: CILocalTip? = nil) -> CIVerdict {
        CIVerdict(status: CIStatus(pullRequest: pullRequest, checks: checks), tip: tip)
    }

    func testPullRequestPrecedence() {
        XCTAssertEqual(verdict(pr(.merged), [check(.failing)]), .merged, "nothing left to act on")
        XCTAssertEqual(verdict(pr(merge: "DIRTY"), [check(.failing), check(.passing)]), .failing(count: 1, total: 2), "red first")
        XCTAssertEqual(verdict(pr(merge: "DIRTY"), [check(.passing)]), .mergeConflict)
        XCTAssertEqual(verdict(pr(), [check(.pending), check(.passing), check(.skipped)]), .running(done: 1, total: 2))
        XCTAssertEqual(verdict(pr(review: "CHANGES_REQUESTED", merge: "BLOCKED"), [check(.passing)]), .changesRequested)
        XCTAssertEqual(verdict(pr(draft: true, review: "REVIEW_REQUIRED"), [check(.passing)]), .draft)
        XCTAssertEqual(verdict(pr(review: "REVIEW_REQUIRED", merge: "BLOCKED"), [check(.passing)]), .waitingForReview)
        XCTAssertEqual(verdict(pr(merge: "BLOCKED"), [check(.passing)]), .blocked)
        XCTAssertEqual(verdict(pr(merge: "CLEAN"), [check(.passing)]), .readyToMerge(optionalFailures: 0))
        XCTAssertEqual(verdict(pr(merge: "UNKNOWN"), [check(.passing)]), .passing, "never claim ready on an unknown merge state")
    }

    /// Unprotected repositories report every failure as UNSTABLE, so only an
    /// explicit "not required" may make a failure optional.
    func testOnlyAKnownOptionalFailureDoesNotBlock() {
        XCTAssertEqual(verdict(pr(merge: "UNSTABLE"), [check(.failing)]), .failing(count: 1, total: 1))
        XCTAssertEqual(
            verdict(pr(merge: "UNSTABLE"), [check(.failing, required: false), check(.passing, required: true)]),
            .readyToMerge(optionalFailures: 1)
        )
    }

    /// A row says less than the Checks tab: nothing for finished work or an
    /// empty PR, and a pass only when a check actually passed.
    func testRowBadge() {
        func badge(_ pullRequest: GhPullRequest?, _ checks: [CICheck], fixing: Bool = false) -> CIRowBadge? {
            CIRowBadge(status: CIStatus(pullRequest: pullRequest, checks: checks), isFixing: fixing)
        }
        XCTAssertEqual(badge(nil, [check(.failing), check(.passing)]), .failing(count: 1, total: 2))
        XCTAssertEqual(badge(nil, [check(.pending), check(.passing)]), .running(done: 1, total: 2))
        XCTAssertEqual(badge(nil, [check(.failing)], fixing: true), .fixing)
        XCTAssertEqual(badge(pr(merge: "DIRTY"), [check(.passing)]), .conflict)
        XCTAssertEqual(badge(pr(review: "REVIEW_REQUIRED"), [check(.passing)]), .passed, "review state is the Checks tab's job")
        XCTAssertEqual(badge(pr(merge: "UNSTABLE"), [check(.failing, required: false), check(.passing, required: true)]), .passed)
        XCTAssertNil(badge(pr(.merged), [check(.failing)]))
        XCTAssertNil(badge(pr(draft: true), []), "no checks, nothing to claim")
        XCTAssertNil(badge(nil, [check(.skipped)]))
        XCTAssertNil(CIRowBadge(status: nil, isFixing: false))
    }

    func testBareCommitVerdicts() {
        XCTAssertEqual(verdict(nil, [check(.failing)]), .failing(count: 1, total: 1))
        XCTAssertEqual(verdict(nil, [check(.pending), check(.passing)]), .running(done: 1, total: 2))
        XCTAssertEqual(verdict(nil, [check(.passing)]), .commitPassing)
        XCTAssertEqual(CIVerdict(status: nil, tip: CILocalTip(sha: "a", unpushedCount: 2)), .notPushed)
        XCTAssertEqual(CIVerdict(status: nil, tip: CILocalTip(sha: "a", unpushedCount: 0)), .noChecks)
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
            ["pr view feature", "rev-parse HEAD", "run list --commit", "run view 9"]
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

    func testDirectPushGetsOneRowPerJob() async throws {
        let runner = ScriptedRunner()
        runner.results["pr view"] = CommandResult(exitCode: 1, stdout: "", stderr: "no pull requests found")
        runner.results["rev-parse HEAD"] = CommandResult(exitCode: 0, stdout: "abc\n", stderr: "")
        runner.results["run list"] = CommandResult(exitCode: 0, stdout: #"[{"databaseId": 9, "workflowName": "Build", "status": "completed", "conclusion": "failure", "url": "https://x/9", "headSha": "abc"}]"#, stderr: "")
        runner.results["run view"] = CommandResult(exitCode: 0, stdout: #"{"jobs":[{"databaseId":71,"name":"unit tests","status":"completed","conclusion":"failure"},{"databaseId":72,"name":"lint","status":"completed","conclusion":"success"}]}"#, stderr: "")

        let status = try await GhService(ghExecutable: gh, runner: runner).ciStatus(forBranch: "feature", at: repo)

        XCTAssertEqual(status?.commitSHA, "abc")
        XCTAssertEqual(status?.checks.map(\.name), ["unit tests", "lint"])
        XCTAssertEqual(status?.failingChecks.first?.jobID, 71)
    }

    private let failingPR = #"{"number":1,"url":"https://x/1","state":"OPEN","headRefOid":"abc","statusCheckRollup":[{"__typename":"CheckRun","name":"build","workflowName":"Build","status":"COMPLETED","conclusion":"FAILURE"},{"__typename":"CheckRun","name":"lint","workflowName":"Build","status":"COMPLETED","conclusion":"FAILURE"}]}"#

    func testRequiredChecksMarkOthersOptional() async throws {
        let runner = ScriptedRunner()
        runner.results["pr view"] = CommandResult(exitCode: 0, stdout: failingPR, stderr: "")
        runner.results["pr checks"] = CommandResult(exitCode: 1, stdout: #"[{"name":"build","workflow":"Build"}]"#, stderr: "")

        let status = try await GhService(ghExecutable: gh, runner: runner).ciStatus(forBranch: "feature", at: repo)

        XCTAssertEqual(status?.blockingFailures.map(\.name), ["build"], "the answer counts even when gh exits non-zero")
    }

    func testNoRequiredChecksMeansEveryFailureBlocks() async throws {
        let runner = ScriptedRunner()
        runner.results["pr view"] = CommandResult(exitCode: 0, stdout: failingPR, stderr: "")
        runner.results["pr checks"] = CommandResult(exitCode: 1, stdout: "", stderr: "no required checks reported on the 'feature' branch")

        let status = try await GhService(ghExecutable: gh, runner: runner).ciStatus(forBranch: "feature", at: repo)

        XCTAssertEqual(status?.blockingFailures.count, 2)
    }

    func testClosedPullRequestBehindTheTipIsJudgedByTheCommit() async throws {
        let runner = ScriptedRunner()
        runner.results["pr view"] = CommandResult(exitCode: 0, stdout: #"{"number":1,"url":"https://x/1","state":"CLOSED","headRefOid":"old","statusCheckRollup":[]}"#, stderr: "")
        runner.results["rev-parse HEAD"] = CommandResult(exitCode: 0, stdout: "new\n", stderr: "")
        runner.results["run list"] = CommandResult(exitCode: 0, stdout: #"[{"databaseId": 9, "workflowName": "Build", "status": "completed", "conclusion": "success", "url": "https://x/9", "headSha": "new"}]"#, stderr: "")

        let status = try await GhService(ghExecutable: gh, runner: runner).ciStatus(forBranch: "feature", at: repo)

        XCTAssertNil(status?.pullRequest, "the closed PR no longer describes this branch")
        XCTAssertEqual(status?.commitSHA, "new")
    }

    func testJobLogRetriesWithoutTheFlagOnOlderGh() async throws {
        let runner = ScriptedRunner()
        let path = "repos/{owner}/{repo}/actions/jobs/5/logs"
        runner.results["api --allow-escape-sequences"] = CommandResult(exitCode: 1, stdout: "", stderr: "unknown flag: --allow-escape-sequences")
        runner.results["api \(path)"] = CommandResult(exitCode: 0, stdout: "the log", stderr: "")

        let log = try await GhService(ghExecutable: gh, runner: runner).jobLog(jobID: 5, at: repo)

        XCTAssertEqual(log, "the log")
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

    private func status(_ state: CICheckState, commit: String? = nil, pullRequest: GhPullRequest? = nil, required: Bool? = nil) -> CIStatus {
        CIStatus(pullRequest: pullRequest, checks: [CICheck(name: "unit tests", state: state, runID: 1, jobID: 2, isRequired: required)], commitSHA: commit)
    }

    private func isolatedDefaults() -> UserDefaults {
        let name = "CIStatusStoreTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        addTeardownBlock { defaults.removePersistentDomain(forName: name) }
        return defaults
    }

    private func pr(_ state: GhPullRequest.State) -> GhPullRequest {
        GhPullRequest(number: 1, url: URL(string: "https://x/1")!, state: state)
    }

    /// A user should hear about CI going red exactly once — not for a branch
    /// that was already red when Flotilla started, and not again on every poll.
    func testFailureNotifiesOnlyOnObservedTransition() async {
        let gh = MockGhService()
        let tracked = session("tracked", branch: "feature")
        let store = CIStatusStore(ghService: gh, sessions: { [tracked] }, defaults: isolatedDefaults())
        var notified: [String] = []
        store.onFailure = { session, check in notified.append("\(session.title):\(check.name)") }

        gh.ciStatusByBranch["feature"] = status(.pending)
        await store.refresh(sessionID: tracked.id)
        gh.ciStatusByBranch["feature"] = status(.failing)
        await store.refresh(sessionID: tracked.id)
        await store.refresh(sessionID: tracked.id)

        XCTAssertEqual(notified, ["tracked:unit tests"])
        XCTAssertEqual(store.needsYouSessionIDs, [tracked.id])

        let alreadyRed = session("already red", branch: "red")
        let coldStore = CIStatusStore(ghService: gh, sessions: { [alreadyRed] }, defaults: isolatedDefaults())
        coldStore.onFailure = { _, _ in notified.append("cold") }
        gh.ciStatusByBranch["red"] = status(.failing)
        await coldStore.refresh(sessionID: alreadyRed.id)
        XCTAssertFalse(notified.contains("cold"), "a failure present at first sight is not an event")
        XCTAssertEqual(coldStore.needsYouSessionIDs, [alreadyRed.id], "but it still counts as failing")
    }

    func testFailureAfterAnEmptyAnswerAndOnANewCommitAreNews() {
        let red = status(.failing, commit: "a")
        XCTAssertTrue(CIStatusStore.isNewFailure(previous: nil, current: red, hadBaseline: true), "no checks, then red")
        XCTAssertFalse(CIStatusStore.isNewFailure(previous: nil, current: red, hadBaseline: false), "first look ever")
        XCTAssertFalse(CIStatusStore.isNewFailure(previous: red, current: red, hadBaseline: true), "same commit")
        XCTAssertTrue(CIStatusStore.isNewFailure(previous: red, current: status(.failing, commit: "b"), hadBaseline: true), "the fix failed too")
        XCTAssertFalse(CIStatusStore.isNewFailure(previous: nil, current: status(.failing, commit: "a", required: false), hadBaseline: true), "optional")
        XCTAssertFalse(CIStatusStore.isNewFailure(previous: nil, current: status(.failing, commit: "a", pullRequest: pr(.closed)), hadBaseline: true), "closed")
    }

    func testNeedsYouOnlyCountsWorkThatCanStillChange() async {
        let gh = MockGhService()
        let tracked = session("tracked", branch: "feature")
        let store = CIStatusStore(ghService: gh, sessions: { [tracked] }, defaults: isolatedDefaults())

        for ignored in [status(.failing, commit: "a", pullRequest: pr(.closed)), status(.failing, commit: "a", pullRequest: pr(.merged)), status(.failing, commit: "a", required: false)] {
            gh.ciStatusByBranch["feature"] = ignored
            await store.refresh(sessionID: tracked.id)
            XCTAssertTrue(store.needsYouSessionIDs.isEmpty)
        }
    }

    func testDismissLastsForThatCommitAcrossRelaunchOnly() async {
        let gh = MockGhService()
        let tracked = session("tracked", branch: "feature")
        let defaults = isolatedDefaults()
        let store = CIStatusStore(ghService: gh, sessions: { [tracked] }, defaults: defaults)
        gh.ciStatusByBranch["feature"] = status(.failing, commit: "a")
        await store.refresh(sessionID: tracked.id)

        store.dismissFailure(sessionID: tracked.id)
        XCTAssertTrue(store.needsYouSessionIDs.isEmpty)

        let relaunched = CIStatusStore(ghService: gh, sessions: { [tracked] }, defaults: defaults)
        await relaunched.refresh(sessionID: tracked.id)
        XCTAssertTrue(relaunched.needsYouSessionIDs.isEmpty, "a dismissal outlives the launch")

        gh.ciStatusByBranch["feature"] = status(.failing, commit: "b")
        await relaunched.refresh(sessionID: tracked.id)
        XCTAssertEqual(relaunched.needsYouSessionIDs, [tracked.id], "a later commit's failure asks again")
    }

    func testAgentFixingLeavesNeedsYouUntilItStopsOrACommitLands() async throws {
        let gh = MockGhService()
        let stopped = session("stopped", branch: "feature", status: .readyForReview)
        let store = CIStatusStore(ghService: gh, sessions: { [stopped] }, defaults: isolatedDefaults())
        var sent: [String] = []
        store.deliver = { prompt, _ in sent.append(prompt) }
        gh.ciStatusByBranch["feature"] = status(.failing, commit: "a")
        await store.refresh(sessionID: stopped.id)

        try await store.sendFailuresToAgent(sessionID: stopped.id)

        XCTAssertEqual(sent.count, 1)
        XCTAssertTrue(store.needsYouSessionIDs.isEmpty, "the agent has just been asked")
        XCTAssertNotNil(store.snapshot(for: stopped.id).fix)

        gh.ciStatusByBranch["feature"] = status(.failing, commit: "b")
        await store.refresh(sessionID: stopped.id)
        XCTAssertNil(store.snapshot(for: stopped.id).fix, "a new commit ends the attempt; its own result decides")
        XCTAssertEqual(store.needsYouSessionIDs, [stopped.id])

        let sentAt = Date()
        let attempt = CIFixAttempt(commitSHA: "b", sentAt: sentAt)
        let later = sentAt.addingTimeInterval(CIStatusStore.fixGracePeriod + 1)
        XCTAssertTrue(CIStatusStore.isFixUnderWay(attempt, sessionStatus: .readyForReview, now: sentAt))
        XCTAssertTrue(CIStatusStore.isFixUnderWay(attempt, sessionStatus: .working, now: later))
        XCTAssertFalse(CIStatusStore.isFixUnderWay(attempt, sessionStatus: .readyForReview, now: later), "stopped without a commit")
    }

    func testPromptCoversEveryFailureAndPointsAtTheFullLog() {
        let failures = [
            (check: CICheck(name: "unit tests", workflowName: "Build", state: .failing, url: URL(string: "https://x/1"), jobID: 5), excerpt: "XCTAssert failed"),
            (check: CICheck(name: "ci/circleci", state: .failing, url: URL(string: "https://x/2")), excerpt: ""),
        ]
        let prompt = CIStatusStore.prompt(failures: failures, branch: "feature", commitSHA: "abcdef1234")

        XCTAssertTrue(prompt.contains("feature at commit abcdef1"))
        XCTAssertTrue(prompt.contains("unit tests (Build)"))
        XCTAssertTrue(prompt.contains("XCTAssert failed"))
        XCTAssertTrue(prompt.contains("gh run view --job 5 --log-failed"))
        XCTAssertTrue(prompt.contains("https://x/2"), "a check with no log still gets its link")
    }

    func testAnEmptyAnswerKeepsTheLastResultAndTheTipMarksItOlder() async {
        let gh = MockGhService()
        let tracked = session("tracked", branch: "feature")
        let store = CIStatusStore(ghService: gh, sessions: { [tracked] }, defaults: isolatedDefaults())
        gh.ciStatusByBranch["feature"] = status(.failing, commit: "a")
        await store.refresh(sessionID: tracked.id)

        gh.ciStatusByBranch["feature"] = nil
        gh.localTipToReturn = CILocalTip(sha: "b", unpushedCount: 1)
        await store.refresh(sessionID: tracked.id)

        XCTAssertEqual(store.status(for: tracked.id)?.commitSHA, "a", "an unpushed commit doesn't erase the last answer")
        XCTAssertTrue(store.snapshot(for: tracked.id).isForOlderCommit)
        XCTAssertEqual(store.needsYouSessionIDs, [tracked.id])
    }

    func testGhErrorsKeepTheResultAndSayWhy() async {
        let gh = MockGhService()
        let tracked = session("tracked", branch: "feature")
        let store = CIStatusStore(ghService: gh, sessions: { [tracked] }, defaults: isolatedDefaults())
        gh.ciStatusByBranch["feature"] = status(.passing, commit: "a")
        await store.refresh(sessionID: tracked.id)

        gh.ciErrorToThrow = GitServiceError.ghCommandFailed(exitCode: 4, stderr: "To get started with GitHub CLI, please run: gh auth login")
        await store.refresh(sessionID: tracked.id)

        XCTAssertEqual(store.snapshot(for: tracked.id).problem, .signedOut)
        XCTAssertEqual(store.status(for: tracked.id)?.commitSHA, "a")
    }

    /// A new worktree on a red main isn't this session's failure, unless the
    /// user opted in or a pull request ties that commit to the branch.
    func testCIFromBeforeTheSessionIsHiddenUntilItCommits() async {
        let gh = MockGhService()
        let tracked = session("tracked", branch: "feature")
        let store = CIStatusStore(ghService: gh, sessions: { [tracked] }, defaults: isolatedDefaults())
        var notified = 0
        store.onFailure = { _, _ in notified += 1 }
        var showsBefore = false
        store.showsCIBeforeSessionCommits = { showsBefore }
        gh.localTipToReturn = CILocalTip(sha: "base", unpushedCount: 0, preSessionCommits: ["base"])
        gh.ciStatusByBranch["feature"] = status(.failing, commit: "base")
        await store.refresh(sessionID: tracked.id)

        XCTAssertNil(store.status(for: tracked.id))
        XCTAssertTrue(store.needsYouSessionIDs.isEmpty)
        XCTAssertTrue(store.snapshot(for: tracked.id).isWaitingForFirstCommit)

        gh.localTipToReturn = CILocalTip(sha: "mine", unpushedCount: 1, preSessionCommits: ["base"])
        gh.ciStatusByBranch["feature"] = nil
        await store.refresh(sessionID: tracked.id)
        XCTAssertTrue(store.needsYouSessionIDs.isEmpty, "an unpushed commit must not resurrect the base's red")

        showsBefore = true
        XCTAssertEqual(store.needsYouSessionIDs, [tracked.id], "the setting applies at once")
        showsBefore = false

        gh.localTipToReturn = CILocalTip(sha: "mine", unpushedCount: 0, preSessionCommits: ["base"])
        gh.ciStatusByBranch["feature"] = status(.failing, commit: "mine")
        await store.refresh(sessionID: tracked.id)
        XCTAssertEqual(store.needsYouSessionIDs, [tracked.id])
        XCTAssertEqual(notified, 1, "the session's own failure is news; the base's was not")

        let withPR = status(.failing, commit: "base", pullRequest: pr(.open))
        XCTAssertFalse(CIStatusStore.isFromBeforeSession(withPR, tip: CILocalTip(sha: "base", unpushedCount: 0, preSessionCommits: ["base"])))
    }

    func testPollIntervalFollowsWhatCanStillChange() {
        let now = Date()
        let tip = CILocalTip(sha: "b", unpushedCount: 0)
        let mixed = CIStatus(checks: [CICheck(name: "a", state: .failing), CICheck(name: "b", state: .pending)], commitSHA: "b")
        func interval(_ status: CIStatus?, awaiting: Date? = nil) -> TimeInterval {
            CIStatusStore.pollInterval(status: status, tip: tip, awaitingCIUntil: awaiting, now: now)
        }

        XCTAssertEqual(interval(mixed), CIStatusStore.pendingInterval, "red with jobs still running")
        XCTAssertEqual(interval(status(.passing, commit: "b")), CIStatusStore.settledInterval)
        XCTAssertEqual(interval(status(.passing, commit: "a"), awaiting: now.addingTimeInterval(60)), CIStatusStore.pendingInterval, "just pushed")
        XCTAssertEqual(interval(status(.passing, commit: "a"), awaiting: now.addingTimeInterval(-1)), CIStatusStore.settledInterval, "no CI came")
    }

    func testSessionsWithoutAWorktreeBranchAreNeverPolled() async {
        let gh = MockGhService()
        let mainCheckout = session("main checkout", branch: nil)
        let store = CIStatusStore(ghService: gh, sessions: { [mainCheckout] }, defaults: isolatedDefaults())

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

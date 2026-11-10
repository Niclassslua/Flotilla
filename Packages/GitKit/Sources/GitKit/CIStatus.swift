import Foundation

/// The outcome of one CI check, folded down to the four answers the UI has to
/// give. GitHub reports a dozen conclusions; most of them mean the same thing
/// to someone deciding whether a branch is broken.
public enum CICheckState: String, Codable, Sendable, Equatable {
    case pending
    case passing
    case failing
    /// Skipped, neutral, or cancelled: ran (or chose not to) without saying
    /// anything about the code. Never makes a branch red or green on its own.
    case skipped
}

public struct CICheck: Identifiable, Equatable, Sendable {
    public var name: String
    public var workflowName: String?
    public var state: CICheckState
    public var url: URL?
    /// The Actions run this check belongs to, when it came from GitHub
    /// Actions — what `gh run view --log-failed` needs. `nil` for external
    /// status contexts, which have no fetchable log.
    public var runID: Int?
    /// The Actions job, when known — what per-job logs are fetched by.
    public var jobID: Int?
    /// `false` when GitHub reports other checks as required and this is not
    /// one of them. `nil` means unknown, and is treated as blocking.
    public var isRequired: Bool?
    public var startedAt: Date?
    public var completedAt: Date?

    public var id: String { "\(workflowName ?? "")/\(name)" }

    public init(
        name: String,
        workflowName: String? = nil,
        state: CICheckState,
        url: URL? = nil,
        runID: Int? = nil,
        jobID: Int? = nil,
        isRequired: Bool? = nil,
        startedAt: Date? = nil,
        completedAt: Date? = nil
    ) {
        self.name = name
        self.workflowName = workflowName
        self.state = state
        self.url = url
        self.runID = runID
        self.jobID = jobID
        self.isRequired = isRequired
        self.startedAt = startedAt
        self.completedAt = completedAt
    }
}

public struct GhPullRequest: Equatable, Sendable {
    public enum State: String, Sendable, Equatable {
        case open = "OPEN"
        case closed = "CLOSED"
        case merged = "MERGED"
    }

    public var number: Int
    public var url: URL
    public var state: State
    public var isDraft: Bool
    /// `APPROVED`, `CHANGES_REQUESTED`, `REVIEW_REQUIRED`, or `nil` when the
    /// repository does not require reviews.
    public var reviewDecision: String?
    public var headSHA: String?
    /// GitHub's `mergeStateStatus`: `CLEAN`, `DIRTY`, `BLOCKED`, `UNSTABLE`, …
    /// Says nothing reliable about which failures block: a repository without
    /// branch protection reports any failure as `UNSTABLE`.
    public var mergeStateStatus: String?

    public init(
        number: Int,
        url: URL,
        state: State,
        isDraft: Bool = false,
        reviewDecision: String? = nil,
        headSHA: String? = nil,
        mergeStateStatus: String? = nil
    ) {
        self.number = number
        self.url = url
        self.state = state
        self.isDraft = isDraft
        self.reviewDecision = reviewDecision
        self.headSHA = headSHA
        self.mergeStateStatus = mergeStateStatus
    }
}

/// Where the local worktree stands relative to what GitHub can see.
public struct CILocalTip: Equatable, Sendable {
    public var sha: String
    public var unpushedCount: Int
    /// Commits this worktree sat on before its first commit of its own. CI
    /// on these describes where the work started, not the work.
    public var preSessionCommits: Set<String>

    public var isPushed: Bool { unpushedCount == 0 }

    public init(sha: String, unpushedCount: Int, preSessionCommits: Set<String> = []) {
        self.sha = sha
        self.unpushedCount = unpushedCount
        self.preSessionCommits = preSessionCommits
    }
}

/// What CI currently says about one branch: its pull request, if it has one,
/// and the checks on one commit.
public struct CIStatus: Equatable, Sendable {
    public var pullRequest: GhPullRequest?
    public var checks: [CICheck]
    /// The commit these checks describe, which is not always the local tip.
    public var commitSHA: String?

    public init(pullRequest: GhPullRequest? = nil, checks: [CICheck], commitSHA: String? = nil) {
        self.pullRequest = pullRequest
        self.checks = checks
        self.commitSHA = commitSHA
    }

    /// Red beats yellow beats green: one failing check makes the branch
    /// failing even while others still run, because that is already the
    /// answer. `nil` when nothing has reported yet.
    public var state: CICheckState? {
        if checks.contains(where: { $0.state == .failing }) { return .failing }
        if checks.contains(where: { $0.state == .pending }) { return .pending }
        if checks.contains(where: { $0.state == .passing }) { return .passing }
        return checks.isEmpty ? nil : .skipped
    }

    public var failingChecks: [CICheck] { checks.filter { $0.state == .failing } }

    /// Failures that hold the branch back. Unknown requirement counts as
    /// blocking: a false alarm is cheaper than a silent red build.
    public var blockingFailures: [CICheck] { failingChecks.filter { $0.isRequired != false } }

    /// What a fix should target: blocking failures, or if only optional
    /// checks are red, those.
    public var failuresToFix: [CICheck] { blockingFailures.isEmpty ? failingChecks : blockingFailures }

    public var hasPendingChecks: Bool { checks.contains { $0.state == .pending } }

    /// Whether this result can still ask anything of the user.
    public var isActionable: Bool { (pullRequest?.state ?? .open) == .open }

    /// Once the PR is merged or closed nothing on the branch will change, so
    /// polling can stop.
    public var isSettledForever: Bool {
        guard let pullRequest else { return false }
        return pullRequest.state != .open
    }
}

/// The one answer the Checks tab leads with: what state this work is in and,
/// by implication, what to do next. A pull request adds review and merge
/// states; a bare commit can only be running, red, green, or not on GitHub.
public enum CIVerdict: Equatable, Sendable {
    case merged
    case closed
    case failing(count: Int, total: Int)
    case mergeConflict
    case running(done: Int, total: Int)
    case changesRequested
    case draft
    case waitingForReview
    case blocked
    case readyToMerge(optionalFailures: Int)
    case passing
    case commitPassing
    case skipped
    case notPushed
    case noChecks

    public init(status: CIStatus?, tip: CILocalTip?) {
        guard let status, status.pullRequest != nil || !status.checks.isEmpty else {
            self = tip?.isPushed == false ? .notPushed : .noChecks
            return
        }
        let counted = status.checks.filter { $0.state != .skipped }
        if status.pullRequest?.state == .merged { self = .merged; return }
        if status.pullRequest?.state == .closed { self = .closed; return }
        let blocking = status.blockingFailures.count
        if blocking > 0 { self = .failing(count: blocking, total: counted.count); return }
        if status.pullRequest?.mergeStateStatus == "DIRTY" { self = .mergeConflict; return }
        if status.hasPendingChecks {
            self = .running(done: counted.filter { $0.state != .pending }.count, total: counted.count)
            return
        }
        guard let pullRequest = status.pullRequest else {
            self = status.state == .skipped ? .skipped : .commitPassing
            return
        }
        if pullRequest.reviewDecision == "CHANGES_REQUESTED" { self = .changesRequested; return }
        // Before review: a draft nearly always also reports REVIEW_REQUIRED,
        // and nobody is being waited on yet.
        if pullRequest.isDraft { self = .draft; return }
        if pullRequest.reviewDecision == "REVIEW_REQUIRED" { self = .waitingForReview; return }
        switch pullRequest.mergeStateStatus {
        case "BLOCKED":
            self = .blocked
        case "CLEAN", "UNSTABLE", "HAS_HOOKS":
            self = .readyToMerge(optionalFailures: status.failingChecks.count)
        default:
            self = status.checks.isEmpty ? .noChecks : status.state == .skipped ? .skipped : .passing
        }
    }
}

/// CI as a session list row shows it. Narrower than `CIVerdict`: review and
/// merge states belong to the Checks tab, and a row with nothing to say about
/// its checks shows nothing.
public enum CIRowBadge: Equatable, Sendable {
    case failing(count: Int, total: Int)
    case running(done: Int, total: Int)
    case conflict
    case fixing
    case passed

    public init?(status: CIStatus?, isFixing: Bool) {
        guard let status else { return nil }
        if isFixing { self = .fixing; return }
        switch CIVerdict(status: status, tip: nil) {
        case .failing(let count, let total): self = .failing(count: count, total: total)
        case .running(let done, let total): self = .running(done: done, total: total)
        case .mergeConflict: self = .conflict
        case .merged, .closed, .skipped, .notPushed, .noChecks: return nil
        default:
            // Review states reach here too, including a PR with no checks yet.
            guard status.checks.contains(where: { $0.state == .passing }) else { return nil }
            self = .passed
        }
    }
}

/// Decodes `gh … --json` output. Pure, so every quirk of GitHub's payloads is
/// pinned by fixtures rather than discovered against the network.
public enum GhJSON {
    /// `gh pr view <branch> --json number,url,state,isDraft,reviewDecision,headRefOid,mergeStateStatus,statusCheckRollup`
    public static func pullRequestStatus(from data: Data) throws -> CIStatus {
        let payload = try decoder.decode(PRViewPayload.self, from: data)
        guard let url = URL(string: payload.url) else {
            throw DecodingError.dataCorrupted(.init(codingPath: [], debugDescription: "Unparseable PR URL \(payload.url)"))
        }
        let pullRequest = GhPullRequest(
            number: payload.number,
            url: url,
            state: GhPullRequest.State(rawValue: payload.state) ?? .open,
            isDraft: payload.isDraft ?? false,
            reviewDecision: payload.reviewDecision.flatMap { $0.isEmpty ? nil : $0 },
            headSHA: payload.headRefOid,
            mergeStateStatus: payload.mergeStateStatus
        )
        let checks = (payload.statusCheckRollup ?? []).map(check(from:))
        return CIStatus(pullRequest: pullRequest, checks: latestPerName(checks), commitSHA: payload.headRefOid)
    }

    /// `gh run list --commit <sha> --json databaseId,workflowName,status,conclusion,url,headSha,createdAt,updatedAt`
    ///
    /// Run list is the fallback for a tip with no PR. It returns history,
    /// newest first; only the runs for the newest commit describe the tip
    /// as it is now. Callers pass `--commit` so a SHA pushed under any
    /// remote branch name still matches.
    public static func workflowRunChecks(from data: Data) throws -> [CICheck] {
        let runs = try decoder.decode([RunPayload].self, from: data)
        guard let newestSHA = runs.first?.headSha else { return [] }
        var seen = Set<String>()
        var checks: [CICheck] = []
        for run in runs where run.headSha == newestSHA {
            guard seen.insert(run.workflowName).inserted else { continue }
            checks.append(CICheck(
                name: run.workflowName,
                workflowName: run.workflowName,
                state: state(status: run.status, conclusion: run.conclusion),
                url: URL(string: run.url),
                runID: run.databaseId,
                startedAt: run.createdAt,
                completedAt: run.status.lowercased() == "completed" ? run.updatedAt : nil
            ))
        }
        return checks
    }

    /// The Actions run ID inside a check's details URL,
    /// `https://github.com/<owner>/<repo>/actions/runs/<run>/job/<job>`.
    public static func runID(fromDetailsURL url: URL?) -> Int? {
        guard let components = url?.pathComponents,
              let index = components.firstIndex(of: "runs"),
              components.indices.contains(index + 1) else { return nil }
        return Int(components[index + 1])
    }

    /// `gh run view <id> --json jobs`: one row per job, so a branch without
    /// a pull request gets the same rows a pull request's rollup gives.
    public static func jobChecks(from data: Data, workflowName: String?, runID: Int) throws -> [CICheck] {
        let payload = try decoder.decode(RunJobsPayload.self, from: data)
        return payload.jobs.map { job in
            CICheck(
                name: job.name,
                workflowName: workflowName,
                state: state(status: job.status, conclusion: job.conclusion),
                url: job.url.flatMap(URL.init(string:)),
                runID: runID,
                jobID: job.databaseId,
                startedAt: validDate(job.startedAt),
                completedAt: validDate(job.completedAt)
            )
        }
    }

    /// `gh pr checks <branch> --required --json name,workflow`, as `CICheck.id`s.
    public static func requiredCheckIDs(from data: Data) throws -> Set<String> {
        Set(try decoder.decode([RequiredCheckPayload].self, from: data).map { "\($0.workflow ?? "")/\($0.name)" })
    }

    /// `git log -g --format=%H%x09%gs HEAD`, newest first. A worktree's reflog
    /// starts when the worktree does, and survives `git push origin HEAD:main`,
    /// so it can tell a session's commits from the ones it began on even after
    /// they land on the default branch.
    public static func preSessionCommits(fromReflog reflog: String) -> Set<String> {
        var commits = Set<String>()
        for line in reflog.split(separator: "\n").reversed() {
            let fields = line.split(separator: "\t", maxSplits: 1)
            guard fields.count == 2 else { continue }
            if ["commit", "cherry-pick", "revert"].contains(where: { fields[1].hasPrefix($0) }) { break }
            commits.insert(String(fields[0]))
        }
        return commits
    }

    /// The Actions job ID inside a check's details URL.
    public static func jobID(fromDetailsURL url: URL?) -> Int? {
        guard let components = url?.pathComponents,
              let index = components.firstIndex(of: "job"),
              components.indices.contains(index + 1) else { return nil }
        return Int(components[index + 1])
    }

    /// The parts of a job log that explain the failure.
    ///
    /// Real logs run to megabytes and end in post-job cleanup, so the tail is
    /// the wrong place to look. This keeps the lines around anything that
    /// reads like a failure, favouring the earliest (root cause) and latest
    /// (summary) when they don't all fit. Only a log with no recognisable
    /// failure falls back to its tail.
    public static func failureExcerpt(_ log: String, maxBytes: Int = 12_000) -> String {
        let lines = log.split(separator: "\n", omittingEmptySubsequences: false).map(cleanLogLine)
        var ranges: [ClosedRange<Int>] = []
        for (index, line) in lines.enumerated() where isFailureLine(line) {
            let lower = max(0, index - 3)
            let upper = min(lines.count - 1, index + (line.hasPrefix("Failing tests:") ? 40 : 6))
            if let last = ranges.last, last.upperBound + 1 >= lower {
                ranges[ranges.count - 1] = last.lowerBound...max(last.upperBound, upper)
            } else {
                ranges.append(lower...upper)
            }
        }
        guard !ranges.isEmpty else { return tail(lines, maxBytes: maxBytes) }

        func cost(_ range: ClosedRange<Int>) -> Int { lines[range].reduce(0) { $0 + $1.utf8.count + 1 } + 2 }
        var chosen = Set<Int>()
        var used = 0
        var low = 0
        var high = ranges.count - 1
        var fromStart = true
        while low <= high {
            let index = fromStart ? low : high
            if used + cost(ranges[index]) <= maxBytes {
                chosen.insert(index)
                used += cost(ranges[index])
            }
            if fromStart { low += 1 } else { high -= 1 }
            fromStart.toggle()
        }
        // One range bigger than the whole budget: its end is the best we can do.
        guard !chosen.isEmpty else {
            return tail(Array(lines[ranges[ranges.count - 1]]), maxBytes: maxBytes)
        }
        return chosen.sorted()
            .map { lines[ranges[$0]].joined(separator: "\n") }
            .joined(separator: "\n…\n")
    }

    /// The last lines of `text` that fit in `maxBytes`.
    public static func clipped(_ text: String, maxBytes: Int) -> String {
        guard text.utf8.count > maxBytes else { return text }
        return tail(text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init), maxBytes: maxBytes)
    }

    private static let failureMarkers = [
        "##[error]", "Failing tests:", " error: ", "FAIL", "AssertionError", "panic:",
        "Traceback", "npm ERR!", "Fatal error", "XCTAssert",
    ]

    private static func isFailureLine(_ line: String) -> Bool {
        if line.hasPrefix("Test case '"), line.contains("' failed") { return true }
        return failureMarkers.contains { line.contains($0) }
    }

    private static let ansiEscape = try! NSRegularExpression(pattern: "\\x1B\\[[0-9;]*[A-Za-z]")

    /// Drops the byte-order mark, the timestamp GitHub prepends, and terminal
    /// colour codes; none of them help anyone read the failure.
    private static func cleanLogLine(_ raw: Substring) -> String {
        var line = raw.hasPrefix("\u{FEFF}") ? raw.dropFirst() : raw
        if line.first?.isNumber == true, let space = line.firstIndex(of: " "), line[..<space].hasSuffix("Z") {
            line = line[line.index(after: space)...]
        }
        guard line.contains("\u{1B}") else { return String(line) }
        let text = String(line)
        return ansiEscape.stringByReplacingMatches(in: text, range: NSRange(text.startIndex..., in: text), withTemplate: "")
    }

    private static func tail(_ lines: [String], maxBytes: Int) -> String {
        var kept = lines.suffix(150)
        while kept.count > 1, kept.reduce(0, { $0 + $1.utf8.count + 1 }) > maxBytes {
            kept.removeFirst()
        }
        return kept.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Payloads

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let raw = try decoder.singleValueContainer().decode(String.self)
            // GitHub sends "0001-01-01T00:00:00Z" for "not started".
            guard let date = ISO8601DateFormatter().date(from: raw), date.timeIntervalSince1970 > 0 else {
                return .distantPast
            }
            return date
        }
        return decoder
    }()

    private struct PRViewPayload: Decodable {
        let number: Int
        let url: String
        let state: String
        let isDraft: Bool?
        let reviewDecision: String?
        let headRefOid: String?
        let mergeStateStatus: String?
        let statusCheckRollup: [RollupPayload]?
    }

    /// One entry of `statusCheckRollup`: either a `CheckRun` (Actions and
    /// GitHub Apps) or a legacy `StatusContext` (external CI).
    private struct RollupPayload: Decodable {
        let __typename: String?
        // CheckRun
        let name: String?
        let workflowName: String?
        let status: String?
        let conclusion: String?
        let detailsUrl: String?
        let completedAt: Date?
        // StatusContext
        let context: String?
        let state: String?
        let targetUrl: String?
        // Both
        let startedAt: Date?
    }

    private struct RunPayload: Decodable {
        let databaseId: Int
        let workflowName: String
        let status: String
        let conclusion: String?
        let url: String
        let headSha: String
        let createdAt: Date?
        let updatedAt: Date?
    }

    private struct RunJobsPayload: Decodable {
        struct Job: Decodable {
            let databaseId: Int
            let name: String
            let status: String
            let conclusion: String?
            let url: String?
            let startedAt: Date?
            let completedAt: Date?
        }
        let jobs: [Job]
    }

    private struct RequiredCheckPayload: Decodable {
        let name: String
        let workflow: String?
    }

    private static func check(from entry: RollupPayload) -> CICheck {
        if entry.__typename == "StatusContext" || (entry.name == nil && entry.context != nil) {
            return CICheck(
                name: entry.context ?? "status",
                state: contextState(entry.state),
                url: entry.targetUrl.flatMap(URL.init(string:)),
                startedAt: validDate(entry.startedAt)
            )
        }
        let url = entry.detailsUrl.flatMap(URL.init(string:))
        return CICheck(
            name: entry.name ?? "check",
            workflowName: entry.workflowName.flatMap { $0.isEmpty ? nil : $0 },
            state: state(status: entry.status ?? "", conclusion: entry.conclusion),
            url: url,
            runID: runID(fromDetailsURL: url),
            jobID: jobID(fromDetailsURL: url),
            startedAt: validDate(entry.startedAt),
            completedAt: validDate(entry.completedAt)
        )
    }

    /// A re-run reports the same check twice; the later one is the truth.
    private static func latestPerName(_ checks: [CICheck]) -> [CICheck] {
        var byID: [String: CICheck] = [:]
        var order: [String] = []
        for check in checks {
            if let existing = byID[check.id] {
                if (check.startedAt ?? .distantPast) >= (existing.startedAt ?? .distantPast) {
                    byID[check.id] = check
                }
            } else {
                byID[check.id] = check
                order.append(check.id)
            }
        }
        return order.compactMap { byID[$0] }
    }

    private static func validDate(_ date: Date?) -> Date? {
        guard let date, date != .distantPast else { return nil }
        return date
    }

    static func state(status: String, conclusion: String?) -> CICheckState {
        guard status.uppercased() == "COMPLETED" else { return .pending }
        switch (conclusion ?? "").uppercased() {
        case "SUCCESS": return .passing
        case "SKIPPED", "NEUTRAL", "CANCELLED", "STALE": return .skipped
        case "": return .pending
        default: return .failing // FAILURE, TIMED_OUT, ACTION_REQUIRED, STARTUP_FAILURE
        }
    }

    private static func contextState(_ state: String?) -> CICheckState {
        switch (state ?? "").uppercased() {
        case "SUCCESS": return .passing
        case "FAILURE", "ERROR": return .failing
        default: return .pending // PENDING, EXPECTED
        }
    }
}

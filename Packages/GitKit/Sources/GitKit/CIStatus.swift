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
    public var startedAt: Date?
    public var completedAt: Date?

    public var id: String { "\(workflowName ?? "")/\(name)" }

    public init(
        name: String,
        workflowName: String? = nil,
        state: CICheckState,
        url: URL? = nil,
        runID: Int? = nil,
        startedAt: Date? = nil,
        completedAt: Date? = nil
    ) {
        self.name = name
        self.workflowName = workflowName
        self.state = state
        self.url = url
        self.runID = runID
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

    public init(number: Int, url: URL, state: State, isDraft: Bool = false, reviewDecision: String? = nil) {
        self.number = number
        self.url = url
        self.state = state
        self.isDraft = isDraft
        self.reviewDecision = reviewDecision
    }
}

/// What CI currently says about one branch: its pull request, if it has one,
/// and the checks on its newest commit.
public struct CIStatus: Equatable, Sendable {
    public var pullRequest: GhPullRequest?
    public var checks: [CICheck]

    public init(pullRequest: GhPullRequest? = nil, checks: [CICheck]) {
        self.pullRequest = pullRequest
        self.checks = checks
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

    /// Once the PR is merged or closed nothing on the branch will change, so
    /// polling can stop.
    public var isSettledForever: Bool {
        guard let pullRequest else { return false }
        return pullRequest.state != .open
    }
}

/// Decodes `gh … --json` output. Pure, so every quirk of GitHub's payloads is
/// pinned by fixtures rather than discovered against the network.
public enum GhJSON {
    /// `gh pr view <branch> --json number,url,state,isDraft,reviewDecision,statusCheckRollup`
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
            reviewDecision: payload.reviewDecision.flatMap { $0.isEmpty ? nil : $0 }
        )
        let checks = (payload.statusCheckRollup ?? []).map(check(from:))
        return CIStatus(pullRequest: pullRequest, checks: latestPerName(checks))
    }

    /// `gh run list --branch <b> --json databaseId,workflowName,status,conclusion,url,headSha,createdAt,updatedAt`
    ///
    /// Run list is the fallback for a pushed branch with no PR. It returns
    /// history, newest first; only the runs for the newest commit describe
    /// the branch as it is now.
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

    /// The end of a failing log, which is where the error is. Agents get a
    /// bounded prompt; GitHub logs routinely run to megabytes.
    public static func logTail(_ log: String, maxLines: Int = 150, maxBytes: Int = 12_000) -> String {
        var lines = log.split(separator: "\n", omittingEmptySubsequences: false).suffix(maxLines)
        while lines.count > 1, lines.reduce(0, { $0 + $1.utf8.count + 1 }) > maxBytes {
            lines.removeFirst()
        }
        return lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
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

import Foundation
import Observation
import SessionKit
import GitKit

/// Which issues the Issues tab lists, by whether an agent is on them.
enum ProjectIssueFilter: String, CaseIterable, Identifiable {
    case all
    case unclaimed
    case claimed

    var id: Self { self }

    var title: String {
        switch self {
        case .all: "All"
        case .unclaimed: "No Session"
        case .claimed: "Has Session"
        }
    }
}

/// A project's open GitHub issues, read through `gh`, joined with the
/// sessions started from them. Read-only by design: GitHub stays where issues
/// are edited; this is where they turn into work.
@Observable
@MainActor
final class ProjectIssuesViewModel {
    let ghService: (any GhServiceProtocol)?
    let repository: URL

    private(set) var issues: [GhIssue] = []
    private(set) var isLoading = false
    private(set) var hasLoaded = false
    private(set) var errorMessage: String?
    /// Bodies, loaded on selection: the list call omits them to stay small.
    private(set) var details: [Int: GhIssue] = [:]
    private(set) var detailError: String?
    var query = ""
    var filter: ProjectIssueFilter = .all
    var selectedNumber: Int?

    /// Enough for a real backlog without paging; `gh` returns most recently
    /// updated first, so anything past it is the long tail.
    static let pageSize = 100

    init(ghService: (any GhServiceProtocol)?, repository: URL) {
        self.ghService = ghService
        self.repository = repository
    }

    func load() async {
        guard let ghService else { return }
        isLoading = true
        defer { isLoading = false }
        do {
            let found = try await ghService.openIssues(search: query, limit: Self.pageSize, at: repository)
            guard !Task.isCancelled else { return }
            issues = found
            errorMessage = nil
            if let selectedNumber, !found.contains(where: { $0.number == selectedNumber }) {
                self.selectedNumber = nil
            }
        } catch {
            guard !Task.isCancelled else { return }
            errorMessage = error.localizedDescription
        }
        hasLoaded = true
    }

    func loadDetail(for number: Int) async {
        guard let ghService, details[number] == nil else { return }
        do {
            details[number] = try await ghService.issue(number: number, at: repository)
            detailError = nil
        } catch {
            detailError = error.localizedDescription
        }
    }

    /// The listed issues after the filter, given the project's sessions.
    func visibleIssues(sessions: [Session]) -> [GhIssue] {
        let claimed = Set(sessions.compactMap { $0.linkedIssue?.number })
        switch filter {
        case .all: return issues
        case .unclaimed: return issues.filter { !claimed.contains($0.number) }
        case .claimed: return issues.filter { claimed.contains($0.number) }
        }
    }

    /// Sessions started from issue `number`, newest first. Matched by number
    /// within the project's own sessions, which all share its repository.
    static func sessions(for number: Int, in sessions: [Session]) -> [Session] {
        sessions
            .filter { $0.linkedIssue?.number == number }
            .sorted { $0.createdAt > $1.createdAt }
    }
}

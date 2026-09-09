import Foundation
import Observation
import GitKit
import SessionKit

/// Everything the review window reads and writes: the diff under review, the
/// reviewer's comments and viewed-marks, and the two presentation choices.
///
/// Deliberately does **not** poll. `DiffPanelViewModel` and
/// `SessionGitSidebarViewModel` re-read git every 1.5–2s, which is right for a
/// status panel and wrong here: a review is entered only while the session is
/// `.readyForReview`, so the diff is not moving, and reloading under a
/// half-typed comment would lose both the comment and the reader's place. If
/// the agent resumes, `isStale` says so and the reader chooses when to reload.
@Observable
@MainActor
final class SessionReviewViewModel {
    let session: Session
    let repoPath: URL

    private let gitService: any GitServiceProtocol
    private let repository: any SessionRepository

    // MARK: Presentation

    /// Set through ``setScope(_:)`` rather than assigned directly: changing it
    /// requires a fresh git query, and a `didSet` that spawned one would make
    /// every assignment — including the ones a reload does itself — fire a
    /// second, racing load.
    private(set) var scope: ReviewScope = .branch

    var diffMode: ReviewDiffMode = .sideBySide
    var fileDisplay: ReviewFileDisplay = .allFiles
    var selectedPath: String?

    // MARK: Loaded state

    private(set) var files: [ReviewFile] = []
    private(set) var comments: [ReviewComment] = []
    private(set) var isLoading = false
    private(set) var hasLoadedOnce = false
    private(set) var errorMessage: String?
    /// The agent resumed after the review opened, so what is on screen may no
    /// longer be what is on disk.
    private(set) var isStale = false

    private var viewedFiles: [ReviewedFile] = []

    init(session: Session, gitService: any GitServiceProtocol, repository: any SessionRepository) {
        self.session = session
        self.repoPath = (session.worktree?.worktreePath ?? session.workingDirectory).standardizedFileURL
        self.gitService = gitService
        self.repository = repository
    }

    // MARK: - Derived

    var selectedFile: ReviewFile? {
        guard let selectedPath else { return files.first }
        return files.first { $0.path == selectedPath } ?? files.first
    }

    /// The files the diff pane draws, which is every file in `.allFiles` and
    /// just the selection in `.singleFile`.
    var visibleFiles: [ReviewFile] {
        switch fileDisplay {
        case .allFiles: files
        case .singleFile: selectedFile.map { [$0] } ?? []
        }
    }

    var viewedCount: Int { files.filter(\.isViewed).count }

    var totalStat: GitDiffStat {
        files.reduce(GitDiffStat(additions: 0, deletions: 0)) { $0 + $1.change.stat }
    }

    /// Only unsent comments are pending: a comment already delivered stays on
    /// screen for reference but must not be sent to the agent twice.
    var unsentComments: [ReviewComment] { comments.filter { !$0.isSent } }

    var canSend: Bool { !unsentComments.isEmpty }

    func comments(for path: String) -> [ReviewComment] {
        comments.filter { $0.filePath == path }
    }

    func fileComments(for path: String) -> [ReviewComment] {
        comments(for: path).filter { $0.anchor == .file }
    }

    /// Comments anchored to one line of one side, in creation order.
    func comments(for path: String, side: ReviewSide, line: Int) -> [ReviewComment] {
        comments(for: path).filter { $0.anchor == .line(side: side, number: line) }
    }

    func hunks(for path: String) -> [ReviewHunk] {
        files.first { $0.path == path }?.hunks ?? []
    }

    // MARK: - Loading

    /// Switches scope and reloads. A no-op if the scope is already selected,
    /// so re-clicking the active button costs nothing.
    func setScope(_ newScope: ReviewScope) async {
        guard newScope != scope else { return }
        scope = newScope
        await load()
    }

    func load() async {
        isLoading = true
        defer {
            isLoading = false
            hasLoadedOnce = true
        }

        do {
            let changes = switch scope {
            case .branch: try await branchChanges()
            case .uncommitted: try await gitService.uncommittedChanges(at: repoPath)
            }

            loadReviewState()
            apply(changes)
            errorMessage = nil
            isStale = false
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// Everything on the branch since it left the default branch, which is
    /// what `changesCompared(to:at:)` computes from the merge-base. Falls back
    /// to the current branch when no default can be resolved, which yields an
    /// empty comparison rather than an error.
    private func branchChanges() async throws -> [GitCommitFileChange] {
        let base = try await gitService.defaultBranch(at: repoPath)
        return try await gitService.changesCompared(to: base, at: repoPath)
    }

    private func loadReviewState() {
        comments = (try? repository.loadReviewComments(sessionID: session.id)) ?? []
        viewedFiles = (try? repository.loadReviewedFiles(sessionID: session.id)) ?? []
    }

    private func apply(_ changes: [GitCommitFileChange]) {
        let previousSelection = selectedPath
        files = changes
            .sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
            .map { change in
                let fingerprint = ReviewDiff.fingerprint(for: change.hunks)
                return ReviewFile(
                    change: change,
                    hunks: ReviewDiff.review(change.hunks),
                    fingerprint: fingerprint,
                    isViewed: isMarkedViewed(path: change.path, fingerprint: fingerprint),
                    commentCount: comments.count { $0.filePath == change.path }
                )
            }

        // Keep the reader where they were if that file still exists; otherwise
        // fall back to the first file rather than an empty pane.
        if let previousSelection, files.contains(where: { $0.path == previousSelection }) {
            selectedPath = previousSelection
        } else {
            selectedPath = files.first?.path
        }
    }

    /// A tick counts only while it still refers to the diff on screen. The
    /// agent can resume and edit a file that was already reviewed, and a mark
    /// that survived that would claim work had been read that never was.
    private func isMarkedViewed(path: String, fingerprint: String) -> Bool {
        viewedFiles.contains {
            $0.filePath == path && $0.scope == scope && $0.diffFingerprint == fingerprint
        }
    }

    /// Called when the session's status leaves `.readyForReview` while the
    /// window is open.
    func markStale() {
        isStale = true
    }

    // MARK: - Viewed marks

    func toggleViewed(_ file: ReviewFile) {
        if file.isViewed {
            try? repository.deleteReviewedFile(sessionID: session.id, scope: scope, filePath: file.path)
            viewedFiles.removeAll { $0.filePath == file.path && $0.scope == scope }
        } else {
            let mark = ReviewedFile(
                sessionID: session.id,
                scope: scope,
                filePath: file.path,
                diffFingerprint: file.fingerprint
            )
            try? repository.saveReviewedFile(mark)
            viewedFiles.removeAll { $0.filePath == file.path && $0.scope == scope }
            viewedFiles.append(mark)
        }
        refreshFileState()
    }

    // MARK: - Comments

    @discardableResult
    func addComment(path: String, anchor: ReviewCommentAnchor, body: String) -> ReviewComment? {
        let trimmed = body.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        let comment = ReviewComment(
            sessionID: session.id,
            filePath: path,
            anchor: anchor,
            body: trimmed
        )
        try? repository.saveReviewComment(comment)
        comments.append(comment)
        refreshFileState()
        return comment
    }

    func updateComment(_ comment: ReviewComment, body: String) {
        let trimmed = body.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            deleteComment(comment)
            return
        }
        guard let index = comments.firstIndex(where: { $0.id == comment.id }) else { return }
        comments[index].body = trimmed
        comments[index].updatedAt = Date()
        try? repository.saveReviewComment(comments[index])
    }

    func deleteComment(_ comment: ReviewComment) {
        try? repository.deleteReviewComment(id: comment.id)
        comments.removeAll { $0.id == comment.id }
        refreshFileState()
    }

    /// Stamps every comment in `delivered` as sent. They stay on screen —
    /// greyed rather than gone — so a second pass can see what was already
    /// asked for.
    func markSent(_ delivered: [ReviewComment], at date: Date = Date()) {
        let ids = Set(delivered.map(\.id))
        for index in comments.indices where ids.contains(comments[index].id) {
            comments[index].sentAt = date
            try? repository.saveReviewComment(comments[index])
        }
    }

    /// Recomputes only the per-file review state, leaving the diff alone —
    /// ticking a box or writing a comment must not re-run git.
    private func refreshFileState() {
        files = files.map { file in
            var updated = file
            updated.isViewed = isMarkedViewed(path: file.path, fingerprint: file.fingerprint)
            updated.commentCount = comments.count { $0.filePath == file.path }
            return updated
        }
    }
}

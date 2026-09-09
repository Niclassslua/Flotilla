import XCTest
import GitKit
import PersistenceKit
import SessionKit
@testable import Flotilla

/// The review's own bookkeeping: which git query each scope issues, when a
/// viewed tick still counts, and which comments are still owed to the agent.
/// All three are invisible when wrong — a stale tick claims work was read that
/// was not, and a mis-scoped query silently reviews the wrong diff.
@MainActor
final class SessionReviewViewModelTests: XCTestCase {
    private let fixedDate = Date(timeIntervalSince1970: 1_700_000_000)

    private func makeSession() -> Session {
        Session(
            title: "Add retry to the uploader",
            goal: "Uploads fail on flaky networks",
            agent: .claudeCode,
            projectID: nil,
            workingDirectory: URL(fileURLWithPath: "/tmp/review-repo"),
            status: .readyForReview,
            createdAt: fixedDate,
            lastActiveAt: fixedDate
        )
    }

    private func change(_ path: String, lines: [String]) -> GitCommitFileChange {
        GitCommitFileChange(
            path: path,
            kind: .modified,
            hunks: [FileDiffHunk(header: "@@ -1,\(lines.count) +1,\(lines.count) @@", lines: lines)]
        )
    }

    private func makeViewModel(
        git: MockGitService,
        repository: GRDBSessionRepository,
        session: Session
    ) -> SessionReviewViewModel {
        SessionReviewViewModel(session: session, gitService: git, repository: repository)
    }

    // MARK: - Scope

    /// The two scopes are different git questions. Asking the wrong one shows
    /// a plausible diff of the wrong thing.
    func testEachScopeIssuesItsOwnGitQuery() async throws {
        let git = MockGitService()
        git.defaultBranchToReturn = "main"
        git.comparisonChangesToReturn = [change("Branch.swift", lines: ["+branch"])]
        git.uncommittedChangesToReturn = [change("Working.swift", lines: ["+working"])]

        let repository = try GRDBSessionRepository()
        let session = makeSession()
        try repository.save(session)
        let viewModel = makeViewModel(git: git, repository: repository, session: session)

        await viewModel.load()
        XCTAssertEqual(viewModel.files.map(\.path), ["Branch.swift"])
        XCTAssertEqual(git.comparisonCalls.map(\.base), ["main"])
        XCTAssertTrue(git.uncommittedChangeCalls.isEmpty)

        await viewModel.setScope(.uncommitted)
        XCTAssertEqual(viewModel.files.map(\.path), ["Working.swift"])
        XCTAssertEqual(git.uncommittedChangeCalls.count, 1)

        // Re-selecting the scope already showing must not re-query.
        await viewModel.setScope(.uncommitted)
        XCTAssertEqual(git.uncommittedChangeCalls.count, 1)
    }

    // MARK: - Viewed marks

    func testMarkingAFileViewedPersistsAndSurvivesAReload() async throws {
        let git = MockGitService()
        git.defaultBranchToReturn = "main"
        git.comparisonChangesToReturn = [change("A.swift", lines: ["+a"])]

        let repository = try GRDBSessionRepository()
        let session = makeSession()
        try repository.save(session)
        let viewModel = makeViewModel(git: git, repository: repository, session: session)
        await viewModel.load()

        let file = try XCTUnwrap(viewModel.files.first)
        XCTAssertFalse(file.isViewed)
        viewModel.toggleViewed(file)
        XCTAssertTrue(try XCTUnwrap(viewModel.files.first).isViewed)

        await viewModel.load()
        XCTAssertTrue(try XCTUnwrap(viewModel.files.first).isViewed)
        XCTAssertEqual(viewModel.viewedCount, 1)
    }

    /// The agent can resume and edit a file that was already ticked. A mark
    /// that survived that would claim the new work had been reviewed.
    func testAFileThatChangedAfterBeingViewedReadsAsUnviewedAgain() async throws {
        let git = MockGitService()
        git.defaultBranchToReturn = "main"
        git.comparisonChangesToReturn = [change("A.swift", lines: ["+a"])]

        let repository = try GRDBSessionRepository()
        let session = makeSession()
        try repository.save(session)
        let viewModel = makeViewModel(git: git, repository: repository, session: session)
        await viewModel.load()
        viewModel.toggleViewed(try XCTUnwrap(viewModel.files.first))
        XCTAssertTrue(try XCTUnwrap(viewModel.files.first).isViewed)

        // The agent edits the same file.
        git.comparisonChangesToReturn = [change("A.swift", lines: ["+a", "+b"])]
        await viewModel.load()

        XCTAssertFalse(try XCTUnwrap(viewModel.files.first).isViewed)
        XCTAssertEqual(viewModel.viewedCount, 0)
    }

    /// The two scopes show different diffs of the same file, so a tick earned
    /// against one must not tick the other.
    func testAViewedMarkDoesNotCarryAcrossScopes() async throws {
        let git = MockGitService()
        git.defaultBranchToReturn = "main"
        git.comparisonChangesToReturn = [change("A.swift", lines: ["+a"])]
        git.uncommittedChangesToReturn = [change("A.swift", lines: ["+a"])]

        let repository = try GRDBSessionRepository()
        let session = makeSession()
        try repository.save(session)
        let viewModel = makeViewModel(git: git, repository: repository, session: session)
        await viewModel.load()
        viewModel.toggleViewed(try XCTUnwrap(viewModel.files.first))

        await viewModel.setScope(.uncommitted)

        XCTAssertFalse(try XCTUnwrap(viewModel.files.first).isViewed)
    }

    // MARK: - Comments

    func testCommentsAreCountedOnTheirFileAndPersist() async throws {
        let git = MockGitService()
        git.defaultBranchToReturn = "main"
        git.comparisonChangesToReturn = [
            change("A.swift", lines: ["+a"]),
            change("B.swift", lines: ["+b"])
        ]

        let repository = try GRDBSessionRepository()
        let session = makeSession()
        try repository.save(session)
        let viewModel = makeViewModel(git: git, repository: repository, session: session)
        await viewModel.load()

        viewModel.addComment(path: "A.swift", anchor: .file, body: "Needs a test.")
        viewModel.addComment(path: "A.swift", anchor: .line(side: .new, number: 1), body: "Off by one.")

        XCTAssertEqual(viewModel.files.first { $0.path == "A.swift" }?.commentCount, 2)
        XCTAssertEqual(viewModel.files.first { $0.path == "B.swift" }?.commentCount, 0)
        XCTAssertEqual(try repository.loadReviewComments(sessionID: session.id).count, 2)

        await viewModel.load()
        XCTAssertEqual(viewModel.comments.count, 2)
    }

    func testBlankCommentsAreRejected() async throws {
        let git = MockGitService()
        git.defaultBranchToReturn = "main"
        git.comparisonChangesToReturn = [change("A.swift", lines: ["+a"])]

        let repository = try GRDBSessionRepository()
        let session = makeSession()
        try repository.save(session)
        let viewModel = makeViewModel(git: git, repository: repository, session: session)
        await viewModel.load()

        XCTAssertNil(viewModel.addComment(path: "A.swift", anchor: .file, body: "   \n  "))
        XCTAssertTrue(viewModel.comments.isEmpty)
    }

    func testFailedCommentPersistenceKeepsTheReviewUnchangedAndShowsTheError() async throws {
        let git = MockGitService()
        git.defaultBranchToReturn = "main"
        git.comparisonChangesToReturn = [change("A.swift", lines: ["+a"])]

        let repository = try GRDBSessionRepository()
        let session = makeSession()
        try repository.save(session)
        let viewModel = makeViewModel(git: git, repository: repository, session: session)
        await viewModel.load()
        let file = try XCTUnwrap(viewModel.files.first)

        // Removing the owning session makes both review writes violate their
        // foreign key, exercising the production repository failure path.
        try repository.delete(sessionID: session.id)

        XCTAssertNil(viewModel.addComment(path: file.path, anchor: .file, body: "Must persist"))
        XCTAssertTrue(viewModel.comments.isEmpty)
        XCTAssertEqual(viewModel.files.first?.commentCount, 0)
        XCTAssertTrue(viewModel.errorMessage?.contains("could not be saved") == true)

        viewModel.toggleViewed(file)
        XCTAssertFalse(try XCTUnwrap(viewModel.files.first).isViewed)
        XCTAssertTrue(viewModel.errorMessage?.contains("viewed state") == true)
    }

    /// Sending must not re-send. A comment already delivered stays on screen
    /// for reference but stops counting as owed.
    func testOnlyUnsentCommentsAreOwedToTheAgent() async throws {
        let git = MockGitService()
        git.defaultBranchToReturn = "main"
        git.comparisonChangesToReturn = [change("A.swift", lines: ["+a"])]

        let repository = try GRDBSessionRepository()
        let session = makeSession()
        try repository.save(session)
        let viewModel = makeViewModel(git: git, repository: repository, session: session)
        await viewModel.load()

        let first = try XCTUnwrap(viewModel.addComment(path: "A.swift", anchor: .file, body: "First pass."))
        XCTAssertTrue(viewModel.canSend)

        try viewModel.markSent([first])

        XCTAssertTrue(viewModel.unsentComments.isEmpty)
        XCTAssertFalse(viewModel.canSend)
        XCTAssertEqual(viewModel.comments.count, 1, "a sent comment stays visible")
        XCTAssertTrue(try XCTUnwrap(repository.loadReviewComments(sessionID: session.id).first).isSent)

        viewModel.addComment(path: "A.swift", anchor: .file, body: "Second pass.")
        XCTAssertEqual(viewModel.unsentComments.map(\.body), ["Second pass."])
    }

    func testEditingASentCommentMakesTheChangedTextUnsent() async throws {
        let git = MockGitService()
        git.defaultBranchToReturn = "main"
        git.comparisonChangesToReturn = [change("A.swift", lines: ["+a"])]

        let repository = try GRDBSessionRepository()
        let session = makeSession()
        try repository.save(session)
        let viewModel = makeViewModel(git: git, repository: repository, session: session)
        await viewModel.load()

        let comment = try XCTUnwrap(viewModel.addComment(path: "A.swift", anchor: .file, body: "First pass."))
        try viewModel.markSent([comment])
        viewModel.updateComment(comment, body: "Changed after delivery.")

        XCTAssertEqual(viewModel.unsentComments.map(\.body), ["Changed after delivery."])
        XCTAssertNil(try XCTUnwrap(repository.loadReviewComments(sessionID: session.id).first).sentAt)
    }

    func testDeletingACommentRemovesItFromTheFileCount() async throws {
        let git = MockGitService()
        git.defaultBranchToReturn = "main"
        git.comparisonChangesToReturn = [change("A.swift", lines: ["+a"])]

        let repository = try GRDBSessionRepository()
        let session = makeSession()
        try repository.save(session)
        let viewModel = makeViewModel(git: git, repository: repository, session: session)
        await viewModel.load()

        let comment = try XCTUnwrap(viewModel.addComment(path: "A.swift", anchor: .file, body: "Never mind."))
        viewModel.deleteComment(comment)

        XCTAssertEqual(viewModel.files.first?.commentCount, 0)
        XCTAssertTrue(try repository.loadReviewComments(sessionID: session.id).isEmpty)
    }

    // MARK: - Presentation

    /// Single File shows only the selection; All Files shows the lot. The
    /// diff pane renders `visibleFiles` directly, so this is the switch.
    func testFileDisplayControlsWhichFilesTheDiffPaneRenders() async throws {
        let git = MockGitService()
        git.defaultBranchToReturn = "main"
        git.comparisonChangesToReturn = [
            change("A.swift", lines: ["+a"]),
            change("B.swift", lines: ["+b"])
        ]

        let repository = try GRDBSessionRepository()
        let session = makeSession()
        try repository.save(session)
        let viewModel = makeViewModel(git: git, repository: repository, session: session)
        await viewModel.load()

        XCTAssertEqual(viewModel.visibleFiles.map(\.path), ["A.swift", "B.swift"])

        viewModel.fileDisplay = .singleFile
        viewModel.selectedPath = "B.swift"
        XCTAssertEqual(viewModel.visibleFiles.map(\.path), ["B.swift"])
    }

    /// Reloading must not throw the reader back to the first file.
    func testReloadKeepsTheSelectedFileWhenItStillExists() async throws {
        let git = MockGitService()
        git.defaultBranchToReturn = "main"
        git.comparisonChangesToReturn = [
            change("A.swift", lines: ["+a"]),
            change("B.swift", lines: ["+b"])
        ]

        let repository = try GRDBSessionRepository()
        let session = makeSession()
        try repository.save(session)
        let viewModel = makeViewModel(git: git, repository: repository, session: session)
        await viewModel.load()
        viewModel.selectedPath = "B.swift"

        await viewModel.load()
        XCTAssertEqual(viewModel.selectedPath, "B.swift")

        // The agent reverts B, so the selection has to fall back somewhere.
        git.comparisonChangesToReturn = [change("A.swift", lines: ["+a"])]
        await viewModel.load()
        XCTAssertEqual(viewModel.selectedPath, "A.swift")
    }
}

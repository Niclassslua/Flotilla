import XCTest
import GRDB
import SessionKit
@testable import PersistenceKit

/// A review is long-lived state the user built by hand — losing a comment, or
/// resurrecting one belonging to a deleted session, is a data-loss bug rather
/// than a cosmetic one.
final class ReviewPersistenceTests: XCTestCase {
    /// GRDB stores `Date` at millisecond precision, so fixtures use a
    /// millisecond-safe timestamp and round-trip equality stays exact.
    private static let fixedDate = Date(timeIntervalSince1970: 1_700_000_000)

    private func repositoryWithSession() throws -> (GRDBSessionRepository, Session) {
        let repo = try GRDBSessionRepository()
        let session = Session(
            title: "Add retry to the uploader",
            goal: "Uploads fail on flaky networks",
            agent: .claudeCode,
            projectID: nil,
            workingDirectory: URL(fileURLWithPath: "/tmp/repo"),
            status: .readyForReview,
            createdAt: Self.fixedDate,
            lastActiveAt: Self.fixedDate
        )
        try repo.save(session)
        return (repo, session)
    }

    // MARK: - Comments

    func testLineAndFileCommentsRoundTrip() throws {
        let (repo, session) = try repositoryWithSession()

        let lineComment = ReviewComment(
            sessionID: session.id,
            filePath: "Sources/Uploader.swift",
            anchor: .line(side: .new, number: 42),
            body: "Only retry 5xx and timeouts.",
            createdAt: Self.fixedDate,
            updatedAt: Self.fixedDate
        )
        let removedSideComment = ReviewComment(
            sessionID: session.id,
            filePath: "Sources/Uploader.swift",
            anchor: .line(side: .old, number: 7),
            body: "Why was this deleted?",
            createdAt: Self.fixedDate.addingTimeInterval(1),
            updatedAt: Self.fixedDate.addingTimeInterval(1)
        )
        let fileComment = ReviewComment(
            sessionID: session.id,
            filePath: "Sources/Transport.swift",
            anchor: .file,
            body: "Split the retry policy out of the transport.",
            createdAt: Self.fixedDate.addingTimeInterval(2),
            updatedAt: Self.fixedDate.addingTimeInterval(2),
            sentAt: Self.fixedDate.addingTimeInterval(3)
        )

        for comment in [lineComment, removedSideComment, fileComment] {
            try repo.saveReviewComment(comment)
        }

        let loaded = try repo.loadReviewComments(sessionID: session.id)

        // Creation order, so a review reads in the order it was written.
        XCTAssertEqual(loaded, [lineComment, removedSideComment, fileComment])
        XCTAssertEqual(loaded[0].anchor, .line(side: .new, number: 42))
        XCTAssertEqual(loaded[1].anchor, .line(side: .old, number: 7))
        XCTAssertEqual(loaded[2].anchor, .file)
        XCTAssertFalse(loaded[0].isSent)
        XCTAssertEqual(loaded[2].sentAt, Self.fixedDate.addingTimeInterval(3))
    }

    func testEditingACommentUpdatesRatherThanDuplicates() throws {
        let (repo, session) = try repositoryWithSession()
        var comment = ReviewComment(
            sessionID: session.id,
            filePath: "README.md",
            anchor: .file,
            body: "Typo here.",
            createdAt: Self.fixedDate,
            updatedAt: Self.fixedDate
        )
        try repo.saveReviewComment(comment)

        comment.body = "Two typos here."
        comment.updatedAt = Self.fixedDate.addingTimeInterval(60)
        try repo.saveReviewComment(comment)

        let loaded = try repo.loadReviewComments(sessionID: session.id)
        XCTAssertEqual(loaded.count, 1)
        XCTAssertEqual(loaded.first?.body, "Two typos here.")
    }

    func testDeletingASessionTakesItsReviewWithIt() throws {
        let (repo, session) = try repositoryWithSession()
        let unrelatedSession = Session(
            title: "Keep this review",
            goal: "Verify deletion isolation",
            agent: .codexCLI,
            projectID: nil,
            workingDirectory: URL(fileURLWithPath: "/tmp/unrelated"),
            status: .readyForReview,
            createdAt: Self.fixedDate,
            lastActiveAt: Self.fixedDate
        )
        try repo.save(unrelatedSession)
        try repo.saveReviewComment(
            ReviewComment(
                sessionID: session.id,
                filePath: "README.md",
                anchor: .line(side: .new, number: 1),
                body: "Stale.",
                createdAt: Self.fixedDate,
                updatedAt: Self.fixedDate
            )
        )
        try repo.saveReviewedFile(
            ReviewedFile(
                sessionID: session.id,
                scope: .branch,
                filePath: "README.md",
                diffFingerprint: "abc",
                viewedAt: Self.fixedDate
            )
        )
        let unrelatedComment = ReviewComment(
            sessionID: unrelatedSession.id,
            filePath: "Keep.swift",
            anchor: .file,
            body: "This must survive.",
            createdAt: Self.fixedDate,
            updatedAt: Self.fixedDate
        )
        try repo.saveReviewComment(unrelatedComment)
        let unrelatedViewedFile = ReviewedFile(
            sessionID: unrelatedSession.id,
            scope: .branch,
            filePath: "Keep.swift",
            diffFingerprint: "keep",
            viewedAt: Self.fixedDate
        )
        try repo.saveReviewedFile(unrelatedViewedFile)

        try repo.delete(sessionID: session.id)

        XCTAssertEqual(try repo.loadReviewComments(sessionID: session.id), [])
        XCTAssertEqual(try repo.loadReviewedFiles(sessionID: session.id), [])
        XCTAssertEqual(try repo.loadReviewComments(sessionID: unrelatedSession.id), [unrelatedComment])
        XCTAssertEqual(try repo.loadReviewedFiles(sessionID: unrelatedSession.id), [unrelatedViewedFile])
    }

    func testMarkingCommentsSentIsAtomicAndSessionScoped() throws {
        let (repo, session) = try repositoryWithSession()
        let first = ReviewComment(
            sessionID: session.id,
            filePath: "A.swift",
            anchor: .file,
            body: "First",
            createdAt: Self.fixedDate,
            updatedAt: Self.fixedDate
        )
        let second = ReviewComment(
            sessionID: session.id,
            filePath: "B.swift",
            anchor: .file,
            body: "Second",
            createdAt: Self.fixedDate.addingTimeInterval(1),
            updatedAt: Self.fixedDate.addingTimeInterval(1)
        )
        try repo.saveReviewComment(first)
        try repo.saveReviewComment(second)

        let sentAt = Self.fixedDate.addingTimeInterval(30)
        try repo.markReviewCommentsSent(sessionID: session.id, commentIDs: [first.id, second.id], at: sentAt)

        let loaded = try repo.loadReviewComments(sessionID: session.id)
        XCTAssertEqual(loaded.map(\.sentAt), [sentAt, sentAt])
        XCTAssertEqual(loaded.map(\.updatedAt), [sentAt, sentAt])
    }

    func testMarkingCommentsSentRollsBackWhenAnyCommentIsMissing() throws {
        let (repo, session) = try repositoryWithSession()
        let comment = ReviewComment(
            sessionID: session.id,
            filePath: "A.swift",
            anchor: .file,
            body: "Keep pending on failure",
            createdAt: Self.fixedDate,
            updatedAt: Self.fixedDate
        )
        try repo.saveReviewComment(comment)

        XCTAssertThrowsError(
            try repo.markReviewCommentsSent(
                sessionID: session.id,
                commentIDs: [comment.id, UUID()],
                at: Self.fixedDate.addingTimeInterval(30)
            )
        )

        let loaded = try XCTUnwrap(repo.loadReviewComments(sessionID: session.id).first)
        XCTAssertNil(loaded.sentAt)
        XCTAssertEqual(loaded.updatedAt, Self.fixedDate)
    }

    // MARK: - Viewed files

    /// Re-viewing a file must replace its fingerprint. Accumulating rows would
    /// leave an old fingerprint able to win and report a changed file as still
    /// reviewed.
    func testReViewingAFileReplacesItsFingerprint() throws {
        let (repo, session) = try repositoryWithSession()
        let first = ReviewedFile(
            sessionID: session.id,
            scope: .branch,
            filePath: "Sources/Uploader.swift",
            diffFingerprint: "fingerprint-one",
            viewedAt: Self.fixedDate
        )
        try repo.saveReviewedFile(first)

        var second = first
        second.diffFingerprint = "fingerprint-two"
        second.viewedAt = Self.fixedDate.addingTimeInterval(120)
        try repo.saveReviewedFile(second)

        let loaded = try repo.loadReviewedFiles(sessionID: session.id)
        XCTAssertEqual(loaded, [second])
    }

    /// The two scopes show different diffs of the same file, so a mark earned
    /// against one must not tick the other.
    func testTheSameFileIsTrackedSeparatelyPerScope() throws {
        let (repo, session) = try repositoryWithSession()
        let path = "Sources/Uploader.swift"
        try repo.saveReviewedFile(
            ReviewedFile(sessionID: session.id, scope: .branch, filePath: path, diffFingerprint: "b", viewedAt: Self.fixedDate)
        )
        try repo.saveReviewedFile(
            ReviewedFile(sessionID: session.id, scope: .uncommitted, filePath: path, diffFingerprint: "u", viewedAt: Self.fixedDate)
        )

        let loaded = try repo.loadReviewedFiles(sessionID: session.id)
        XCTAssertEqual(Set(loaded.map(\.scope)), [.branch, .uncommitted])

        try repo.deleteReviewedFile(sessionID: session.id, scope: .branch, filePath: path)

        let remaining = try repo.loadReviewedFiles(sessionID: session.id)
        XCTAssertEqual(remaining.map(\.scope), [.uncommitted])
    }

    // MARK: - Migration

    /// A database that stopped at v10 — every install predating the review
    /// feature — must reach the review tables by migrating forward.
    func testADatabaseStoppedAtV10UpgradesToTheReviewTables() throws {
        let queue = try DatabaseQueue()
        let migrator = GRDBSessionRepository.migrator

        try migrator.migrate(queue, upTo: "v10_addHandoffSourceModelAndEffort")
        try queue.read { db in
            XCTAssertFalse(try db.tableExists("review_comment"))
            XCTAssertFalse(try db.tableExists("review_viewed_file"))
        }

        try migrator.migrate(queue)
        try queue.read { db in
            XCTAssertTrue(try db.tableExists("review_comment"))
            XCTAssertTrue(try db.tableExists("review_viewed_file"))

            // Every column `ReviewCommentRecord` writes must exist, or the
            // first comment fails on insert rather than at migration time.
            let columns = Set(try db.columns(in: "review_comment").map(\.name))
            for expected in ["id", "sessionID", "filePath", "anchorSide", "anchorLine", "body", "createdAt", "updatedAt", "sentAt"] {
                XCTAssertTrue(columns.contains(expected), "review_comment is missing \(expected)")
            }
        }
    }
}

import XCTest
import GitKit
import SessionKit
@testable import Flotilla

/// The formatted prompt is the entire contract with the agent — if it says the
/// wrong line, or drops a comment, the agent edits the wrong code and nothing
/// in the UI shows that anything went wrong.
final class ReviewPromptFormatterTests: XCTestCase {
    private let sessionID = UUID()

    private func file(path: String, hunk: FileDiffHunk) -> ReviewFile {
        let change = GitCommitFileChange(path: path, kind: .modified, hunks: [hunk])
        return ReviewFile(
            change: change,
            hunks: ReviewDiff.review(change.hunks),
            fingerprint: ReviewDiff.fingerprint(for: change.hunks),
            isViewed: false,
            commentCount: 0
        )
    }

    private func comment(
        path: String,
        anchor: ReviewCommentAnchor,
        body: String,
        offset: TimeInterval = 0
    ) -> ReviewComment {
        ReviewComment(
            sessionID: sessionID,
            filePath: path,
            anchor: anchor,
            body: body,
            createdAt: Date(timeIntervalSince1970: 1_700_000_000 + offset),
            updatedAt: Date(timeIntervalSince1970: 1_700_000_000 + offset)
        )
    }

    func testQuotesTheLineEachCommentIsAnchoredTo() {
        let uploader = file(
            path: "Sources/Uploader.swift",
            hunk: FileDiffHunk(
                header: "@@ -40,2 +40,3 @@",
                lines: [" let chunk = next()", "+try await session.upload(chunk)", "-legacyUpload(chunk)"]
            )
        )

        let prompt = ReviewPromptFormatter.prompt(
            sessionTitle: "Add retry to the uploader",
            branch: "flotilla/retry-uploader",
            comments: [
                comment(
                    path: "Sources/Uploader.swift",
                    anchor: .line(side: .new, number: 41),
                    body: "Only retry 5xx and timeouts."
                )
            ],
            files: [uploader]
        )

        XCTAssertTrue(prompt.contains("## Sources/Uploader.swift"), prompt)
        XCTAssertTrue(prompt.contains("**Line 41** (current):"), prompt)
        XCTAssertTrue(prompt.contains("> `try await session.upload(chunk)`"), prompt)
        XCTAssertTrue(prompt.contains("Only retry 5xx and timeouts."), prompt)
    }

    /// A comment on a deleted line has to say so, or the agent looks for text
    /// that is no longer in the file and concludes the comment is stale.
    func testRemovedLineCommentsAreLabelledAsRemoved() {
        let target = file(
            path: "Sources/Transport.swift",
            hunk: FileDiffHunk(header: "@@ -7,2 +7,1 @@", lines: ["-legacyRetry()", " keep()"])
        )

        let prompt = ReviewPromptFormatter.prompt(
            sessionTitle: "Cleanup",
            branch: nil,
            comments: [
                comment(
                    path: "Sources/Transport.swift",
                    anchor: .line(side: .old, number: 7),
                    body: "Why was this deleted?"
                )
            ],
            files: [target]
        )

        XCTAssertTrue(prompt.contains("**Line 7** (removed):"), prompt)
        XCTAssertTrue(prompt.contains("> `legacyRetry()`"), prompt)
    }

    /// Whole-file remarks set up the specific ones, so they have to come
    /// first regardless of the order they were written in.
    func testFileCommentsPrecedeLineCommentsAndLinesAreOrdered() throws {
        let target = file(
            path: "A.swift",
            hunk: FileDiffHunk(header: "@@ -1,3 +1,3 @@", lines: ["+one", "+two", "+three"])
        )

        let prompt = ReviewPromptFormatter.prompt(
            sessionTitle: "Ordering",
            branch: nil,
            comments: [
                comment(path: "A.swift", anchor: .line(side: .new, number: 3), body: "third"),
                comment(path: "A.swift", anchor: .line(side: .new, number: 1), body: "first", offset: 1),
                comment(path: "A.swift", anchor: .file, body: "overall", offset: 2)
            ],
            files: [target]
        )

        let overall = try XCTUnwrap(prompt.range(of: "overall"))
        let first = try XCTUnwrap(prompt.range(of: "first"))
        let third = try XCTUnwrap(prompt.range(of: "third"))
        XCTAssertTrue(overall.lowerBound < first.lowerBound, "whole-file comment should lead")
        XCTAssertTrue(first.lowerBound < third.lowerBound, "line comments should be in line order")
    }

    func testGroupsCommentsByFileAndCountsThemInTheHeading() {
        let a = file(path: "A.swift", hunk: FileDiffHunk(header: "@@ -1 +1 @@", lines: ["+a"]))
        let b = file(path: "B.swift", hunk: FileDiffHunk(header: "@@ -1 +1 @@", lines: ["+b"]))

        let prompt = ReviewPromptFormatter.prompt(
            sessionTitle: "Two files",
            branch: "topic",
            comments: [
                comment(path: "A.swift", anchor: .file, body: "one"),
                comment(path: "B.swift", anchor: .file, body: "two", offset: 1),
                comment(path: "B.swift", anchor: .file, body: "three", offset: 2)
            ],
            files: [a, b]
        )

        XCTAssertTrue(prompt.contains("3 comments across 2 files"), prompt)
        XCTAssertTrue(prompt.contains("(topic)"), prompt)
        XCTAssertEqual(prompt.components(separatedBy: "## A.swift").count - 1, 1)
        XCTAssertEqual(prompt.components(separatedBy: "## B.swift").count - 1, 1)
    }

    /// An anchor that no longer resolves — the file was re-diffed and the line
    /// moved — must still deliver the reviewer's words rather than vanish.
    func testCommentSurvivesAnUnresolvableAnchorWithoutItsQuote() {
        let target = file(path: "A.swift", hunk: FileDiffHunk(header: "@@ -1 +1 @@", lines: ["+a"]))

        let prompt = ReviewPromptFormatter.prompt(
            sessionTitle: "Moved",
            branch: nil,
            comments: [
                comment(path: "A.swift", anchor: .line(side: .new, number: 999), body: "still matters")
            ],
            files: [target]
        )

        XCTAssertTrue(prompt.contains("still matters"), prompt)
        XCTAssertFalse(prompt.contains("> `"), "no line resolved, so nothing should be quoted")
    }

    func testNoCommentsProducesNoPrompt() {
        XCTAssertTrue(
            ReviewPromptFormatter.prompt(sessionTitle: "Empty", branch: nil, comments: [], files: []).isEmpty
        )
    }
}

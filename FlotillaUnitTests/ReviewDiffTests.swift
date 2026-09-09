import XCTest
import GitKit

/// `ReviewDiff` is what makes a patch reviewable: it recovers the line numbers
/// git states only once, in the hunk header, and pairs the two sides for a
/// two-column view. Both are silent-failure territory — a comment anchored to
/// the wrong line still renders, and a mispaired row still looks like a diff.
final class ReviewDiffTests: XCTestCase {

    // MARK: - Header parsing

    func testParsesFullHunkHeaderWithSection() {
        let parsed = ReviewDiff.parseHunkHeader("@@ -12,7 +14,9 @@ func upload()")
        XCTAssertEqual(parsed?.oldStart, 12)
        XCTAssertEqual(parsed?.oldCount, 7)
        XCTAssertEqual(parsed?.newStart, 14)
        XCTAssertEqual(parsed?.newCount, 9)
        XCTAssertEqual(parsed?.section, "func upload()")
    }

    /// git omits the count for a single-line range, which means `@@ -5 +5 @@`
    /// is a one-line range and not a zero-line one.
    func testParsesShorthandSingleLineRanges() {
        let parsed = ReviewDiff.parseHunkHeader("@@ -5 +7 @@")
        XCTAssertEqual(parsed?.oldStart, 5)
        XCTAssertEqual(parsed?.oldCount, 1)
        XCTAssertEqual(parsed?.newStart, 7)
        XCTAssertEqual(parsed?.newCount, 1)
        XCTAssertEqual(parsed?.section, "")
    }

    /// `changesCompared(to:at:)` invents this header for untracked files. It
    /// carries no numbers, and must not be mistaken for one that does.
    func testRejectsSyntheticUntrackedHeader() {
        XCTAssertNil(ReviewDiff.parseHunkHeader("@@ new untracked file @@"))
        XCTAssertNil(ReviewDiff.parseHunkHeader("not a hunk header"))
    }

    // MARK: - Line numbering

    func testNumbersLinesFromTheHunkHeader() {
        let hunk = FileDiffHunk(
            header: "@@ -10,4 +20,5 @@",
            lines: [" context", "-removed", "+added", "+also added", " trailing"]
        )

        let lines = ReviewDiff.review(hunk).lines

        XCTAssertEqual(lines.map(\.kind), [.context, .removed, .added, .added, .context])
        // The old side counts context and removals; the new side counts
        // context and additions. Neither advances on the other's lines.
        XCTAssertEqual(lines.map(\.oldNumber), [10, 11, nil, nil, 12])
        XCTAssertEqual(lines.map(\.newNumber), [20, nil, 21, 22, 23])
        XCTAssertEqual(lines.map(\.text), ["context", "removed", "added", "also added", "trailing"])
    }

    func testUntrackedFileHunkNumbersFromLineOne() {
        let hunk = FileDiffHunk(
            header: "@@ new untracked file @@",
            lines: ["+first", "+second"]
        )

        let lines = ReviewDiff.review(hunk).lines

        XCTAssertEqual(lines.map(\.newNumber), [1, 2])
        XCTAssertEqual(lines.map(\.oldNumber), [nil, nil])
    }

    /// git's marker annotates the line above it rather than being a line of
    /// its own — counting it would shift every subsequent line number.
    func testNoNewlineMarkerAnnotatesPreviousLineWithoutConsumingANumber() {
        let hunk = FileDiffHunk(
            header: "@@ -1,2 +1,2 @@",
            lines: [" kept", "-old", "\\ No newline at end of file", "+new"]
        )

        let lines = ReviewDiff.review(hunk).lines

        XCTAssertEqual(lines.count, 3)
        XCTAssertTrue(lines[1].lacksTrailingNewline)
        XCTAssertEqual(lines[2].kind, .added)
        XCTAssertEqual(lines[2].newNumber, 2)
    }

    func testCommentsOnRemovedLinesAnchorToTheOldSide() {
        let hunk = FileDiffHunk(header: "@@ -1,1 +1,1 @@", lines: ["-gone", "+here", " same"])
        let lines = ReviewDiff.review(hunk).lines

        XCTAssertEqual(lines[0].commentSide, .old)
        XCTAssertEqual(lines[1].commentSide, .new)
        XCTAssertEqual(lines[2].commentSide, .new)
    }

    // MARK: - Side-by-side pairing

    /// A modified line must read as one row — a removal opposite its
    /// replacement — not as a deletion stranded above an unrelated addition.
    func testPairsRemovalsOppositeAdditionsWithinARun() {
        let hunk = ReviewDiff.review(
            FileDiffHunk(
                header: "@@ -1,3 +1,3 @@",
                lines: [" head", "-a", "-b", "+A", "+B", " tail"]
            )
        )

        let rows = ReviewDiff.sideBySideRows(for: hunk)

        XCTAssertEqual(rows.count, 4)
        XCTAssertTrue(rows[0].isContext)
        XCTAssertEqual(rows[1].left?.text, "a")
        XCTAssertEqual(rows[1].right?.text, "A")
        XCTAssertTrue(rows[1].isModification)
        XCTAssertEqual(rows[2].left?.text, "b")
        XCTAssertEqual(rows[2].right?.text, "B")
        XCTAssertTrue(rows[3].isContext)
    }

    func testUnevenRunLeavesTheShorterSideEmpty() {
        let hunk = ReviewDiff.review(
            FileDiffHunk(header: "@@ -1,1 +1,3 @@", lines: ["-only", "+one", "+two", "+three"])
        )

        let rows = ReviewDiff.sideBySideRows(for: hunk)

        XCTAssertEqual(rows.count, 3)
        XCTAssertEqual(rows[0].left?.text, "only")
        XCTAssertNil(rows[1].left)
        XCTAssertNil(rows[2].left)
        XCTAssertEqual(rows.compactMap(\.right?.text), ["one", "two", "three"])
        // Every row carries at least one side, or the view would render a gap.
        XCTAssertTrue(rows.allSatisfy { $0.left != nil || $0.right != nil })
    }

    /// Two separate runs must not bleed into one another: a removal in the
    /// second run pairing with an addition from the first would show the
    /// reader a change that never happened.
    func testContextBreaksRunsSoPairingDoesNotCrossIt() {
        let hunk = ReviewDiff.review(
            FileDiffHunk(header: "@@ -1,4 +1,4 @@", lines: ["-a", " gap", "+B"])
        )

        let rows = ReviewDiff.sideBySideRows(for: hunk)

        XCTAssertEqual(rows.count, 3)
        XCTAssertEqual(rows[0].left?.text, "a")
        XCTAssertNil(rows[0].right)
        XCTAssertTrue(rows[1].isContext)
        XCTAssertNil(rows[2].left)
        XCTAssertEqual(rows[2].right?.text, "B")
    }

    // MARK: - Fingerprint

    /// The fingerprint is what un-ticks a "viewed" mark when the agent
    /// resumes and edits a file that was already reviewed.
    func testFingerprintChangesWhenContentOrPositionChanges() {
        let original = [FileDiffHunk(header: "@@ -1,1 +1,1 @@", lines: ["+one"])]
        let editedContent = [FileDiffHunk(header: "@@ -1,1 +1,1 @@", lines: ["+two"])]
        let movedHunk = [FileDiffHunk(header: "@@ -9,1 +9,1 @@", lines: ["+one"])]

        let baseline = ReviewDiff.fingerprint(for: original)

        XCTAssertEqual(baseline, ReviewDiff.fingerprint(for: original))
        XCTAssertNotEqual(baseline, ReviewDiff.fingerprint(for: editedContent))
        XCTAssertNotEqual(baseline, ReviewDiff.fingerprint(for: movedHunk))
    }

    /// Concatenating lines without a separator would let two different
    /// splits hash identically.
    func testFingerprintDistinguishesDifferentLineSplits() {
        let split = [FileDiffHunk(header: "@@", lines: ["+ab", "+c"])]
        let joined = [FileDiffHunk(header: "@@", lines: ["+a", "+bc"])]

        XCTAssertNotEqual(ReviewDiff.fingerprint(for: split), ReviewDiff.fingerprint(for: joined))
    }
}

import XCTest
import GitKit

/// `ReviewDiff` is what makes a patch reviewable: it recovers the line numbers
/// git states only once, in the hunk header, and pairs the two sides for a
/// two-column view. Both are silent-failure territory — a comment anchored to
/// the wrong line still renders, and a mispaired row still looks like a diff.
final class ReviewDiffTests: XCTestCase {

    func testParsesHunkHeadersAndRejectsSyntheticOnes() {
        let full = ReviewDiff.parseHunkHeader("@@ -12,7 +14,9 @@ func upload()")
        XCTAssertEqual(full?.oldStart, 12)
        XCTAssertEqual(full?.oldCount, 7)
        XCTAssertEqual(full?.newStart, 14)
        XCTAssertEqual(full?.newCount, 9)
        XCTAssertEqual(full?.section, "func upload()")

        let shorthand = ReviewDiff.parseHunkHeader("@@ -5 +7 @@")
        XCTAssertEqual(shorthand?.oldStart, 5)
        XCTAssertEqual(shorthand?.oldCount, 1)
        XCTAssertEqual(shorthand?.newStart, 7)
        XCTAssertEqual(shorthand?.newCount, 1)
        XCTAssertEqual(shorthand?.section, "")

        XCTAssertNil(ReviewDiff.parseHunkHeader("@@ new untracked file @@"))
        XCTAssertNil(ReviewDiff.parseHunkHeader("not a hunk header"))
    }

    func testLineNumberingAnchorsAndNoNewlineMarker() {
        let numbered = ReviewDiff.review(
            FileDiffHunk(
                header: "@@ -10,4 +20,5 @@",
                lines: [" context", "-removed", "+added", "+also added", " trailing"]
            )
        ).lines
        XCTAssertEqual(numbered.map(\.kind), [.context, .removed, .added, .added, .context])
        XCTAssertEqual(numbered.map(\.oldNumber), [10, 11, nil, nil, 12])
        XCTAssertEqual(numbered.map(\.newNumber), [20, nil, 21, 22, 23])
        XCTAssertEqual(numbered.map(\.text), ["context", "removed", "added", "also added", "trailing"])

        let untracked = ReviewDiff.review(
            FileDiffHunk(header: "@@ new untracked file @@", lines: ["+first", "+second"])
        ).lines
        XCTAssertEqual(untracked.map(\.newNumber), [1, 2])
        XCTAssertEqual(untracked.map(\.oldNumber), [nil, nil])

        let noNewline = ReviewDiff.review(
            FileDiffHunk(
                header: "@@ -1,2 +1,2 @@",
                lines: [" kept", "-old", "\\ No newline at end of file", "+new"]
            )
        ).lines
        XCTAssertEqual(noNewline.count, 3)
        XCTAssertTrue(noNewline[1].lacksTrailingNewline)
        XCTAssertEqual(noNewline[2].kind, .added)
        XCTAssertEqual(noNewline[2].newNumber, 2)

        let sides = ReviewDiff.review(
            FileDiffHunk(header: "@@ -1,1 +1,1 @@", lines: ["-gone", "+here", " same"])
        ).lines
        XCTAssertEqual(sides[0].commentSide, .old)
        XCTAssertEqual(sides[1].commentSide, .new)
        XCTAssertEqual(sides[2].commentSide, .new)
    }

    func testSideBySidePairingRuns() {
        let paired = ReviewDiff.sideBySideRows(for: ReviewDiff.review(
            FileDiffHunk(header: "@@ -1,3 +1,3 @@", lines: [" head", "-a", "-b", "+A", "+B", " tail"])
        ))
        XCTAssertEqual(paired.count, 4)
        XCTAssertTrue(paired[0].isContext)
        XCTAssertEqual(paired[1].left?.text, "a")
        XCTAssertEqual(paired[1].right?.text, "A")
        XCTAssertTrue(paired[1].isModification)
        XCTAssertEqual(paired[2].left?.text, "b")
        XCTAssertEqual(paired[2].right?.text, "B")
        XCTAssertTrue(paired[3].isContext)

        let uneven = ReviewDiff.sideBySideRows(for: ReviewDiff.review(
            FileDiffHunk(header: "@@ -1,1 +1,3 @@", lines: ["-only", "+one", "+two", "+three"])
        ))
        XCTAssertEqual(uneven.count, 3)
        XCTAssertEqual(uneven[0].left?.text, "only")
        XCTAssertNil(uneven[1].left)
        XCTAssertNil(uneven[2].left)
        XCTAssertEqual(uneven.compactMap(\.right?.text), ["one", "two", "three"])
        XCTAssertTrue(uneven.allSatisfy { $0.left != nil || $0.right != nil })

        let broken = ReviewDiff.sideBySideRows(for: ReviewDiff.review(
            FileDiffHunk(header: "@@ -1,4 +1,4 @@", lines: ["-a", " gap", "+B"])
        ))
        XCTAssertEqual(broken.count, 3)
        XCTAssertEqual(broken[0].left?.text, "a")
        XCTAssertNil(broken[0].right)
        XCTAssertTrue(broken[1].isContext)
        XCTAssertNil(broken[2].left)
        XCTAssertEqual(broken[2].right?.text, "B")
    }

    func testFingerprintDistinguishesContentPositionSplitsAndBinary() {
        let original = [FileDiffHunk(header: "@@ -1,1 +1,1 @@", lines: ["+one"])]
        let editedContent = [FileDiffHunk(header: "@@ -1,1 +1,1 @@", lines: ["+two"])]
        let movedHunk = [FileDiffHunk(header: "@@ -9,1 +9,1 @@", lines: ["+one"])]
        let baseline = ReviewDiff.fingerprint(for: original)
        XCTAssertEqual(baseline, ReviewDiff.fingerprint(for: original))
        XCTAssertNotEqual(baseline, ReviewDiff.fingerprint(for: editedContent))
        XCTAssertNotEqual(baseline, ReviewDiff.fingerprint(for: movedHunk))

        let split = [FileDiffHunk(header: "@@", lines: ["+ab", "+c"])]
        let joined = [FileDiffHunk(header: "@@", lines: ["+a", "+bc"])]
        XCTAssertNotEqual(ReviewDiff.fingerprint(for: split), ReviewDiff.fingerprint(for: joined))

        let binary = [FileDiffHunk(header: "@@ binary file @@", lines: [])]
        let originalBinary = ReviewDiff.fingerprint(
            for: binary,
            fallbackContent: Data([0x00, 0x01]),
            fileMode: 0o644
        )
        XCTAssertNotEqual(
            originalBinary,
            ReviewDiff.fingerprint(for: binary, fallbackContent: Data([0x00, 0x02]), fileMode: 0o644)
        )
        XCTAssertNotEqual(
            originalBinary,
            ReviewDiff.fingerprint(for: binary, fallbackContent: Data([0x00, 0x01]), fileMode: 0o755)
        )
    }
}

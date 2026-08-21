import XCTest
import GitKit
@testable import Flotilla

final class GitGraphLayoutTests: XCTestCase {

    private func commit(
        sha: String,
        subject: String = "commit",
        parents: [String] = [],
        authorDate: Date = Date()
    ) -> GitCommit {
        GitCommit(
            sha: sha,
            shortSHA: String(sha.prefix(7)),
            parents: parents,
            authorName: "Tester",
            authorEmail: "test@example.com",
            authorDate: authorDate,
            committerName: "Tester",
            committerEmail: "test@example.com",
            committerDate: authorDate,
            refs: [],
            subject: subject,
            body: "",
            stat: GitDiffStat(additions: 1, deletions: 0),
            changedFileCount: 1
        )
    }

    /// Every edge that leaves a row's bottom edge has to be met by an edge
    /// entering the next row's top edge in the same lane, or the drawn line
    /// breaks between rows. This is the invariant the renderer relies on to
    /// draw each row in isolation.
    private func assertRowsJoin(_ rows: [GitGraphRow], file: StaticString = #filePath, line: UInt = #line) {
        for index in rows.indices.dropLast() {
            let leaving = Set(rows[index].segments.compactMap { segment -> Int? in
                segment.kind == .incoming ? nil : segment.toLane
            })
            let arriving = Set(rows[index + 1].segments.compactMap { segment -> Int? in
                segment.kind == .outgoing ? nil : segment.fromLane
            })
            XCTAssertEqual(
                leaving, arriving,
                "row \(index) (\(rows[index].commit.sha)) leaves lanes \(leaving.sorted()) "
                    + "but row \(index + 1) (\(rows[index + 1].commit.sha)) receives \(arriving.sorted())",
                file: file, line: line
            )
        }
    }

    // MARK: - Linear History

    func testLinearHistoryProducesSingleLane() {
        let c3 = commit(sha: "c3", parents: ["c2"])
        let c2 = commit(sha: "c2", parents: ["c1"])
        let c1 = commit(sha: "c1", parents: [])

        let rows = GitGraphLayout.rows(for: [c3, c2, c1])

        XCTAssertEqual(rows.count, 3)
        XCTAssertEqual(rows.map(\.lane), [0, 0, 0])
        XCTAssertEqual(rows.map(\.laneCount), [1, 1, 1])
        // One unbroken column means one colour the whole way down.
        XCTAssertEqual(Set(rows.map(\.colorIndex)).count, 1)

        // The tip has nothing above it: only a downward edge to its parent.
        XCTAssertEqual(rows[0].segments.map(\.kind), [.outgoing])

        // A middle commit is joined to the row above and the row below.
        XCTAssertEqual(Set(rows[1].segments.map(\.kind)), [.incoming, .outgoing])

        // The root has nothing below it.
        XCTAssertEqual(rows[2].segments.map(\.kind), [.incoming])

        assertRowsJoin(rows)
    }

    // MARK: - Branch and Merge

    func testSimpleBranchAndMerge() {
        // Topology:
        // M (parents: [B1, B2])
        // | \
        // |  B2 (parents: [A])
        // B1 (parents: [A])
        // | /
        // A  (root)
        let m = commit(sha: "M", parents: ["B1", "B2"])
        let b2 = commit(sha: "B2", parents: ["A"])
        let b1 = commit(sha: "B1", parents: ["A"])
        let a = commit(sha: "A", parents: [])

        let rows = GitGraphLayout.rows(for: [m, b2, b1, a])

        XCTAssertEqual(rows.count, 4)

        // M keeps lane 0 for its first parent and fans the second out to the right.
        XCTAssertEqual(rows[0].commit.sha, "M")
        XCTAssertEqual(rows[0].lane, 0)
        XCTAssertTrue(rows[0].segments.contains(
            GitGraphSegment(fromLane: 0, toLane: 0, colorIndex: rows[0].colorIndex, kind: .outgoing)
        ))
        let fanOut = rows[0].segments.first { $0.kind == .outgoing && $0.toLane == 1 }
        XCTAssertNotNil(fanOut)
        XCTAssertNotEqual(fanOut?.colorIndex, rows[0].colorIndex, "a new lane needs a new colour")

        // B2 sits in the fanned-out lane, joined upward to M; B1 passes by in lane 0.
        XCTAssertEqual(rows[1].commit.sha, "B2")
        XCTAssertEqual(rows[1].lane, 1)
        XCTAssertTrue(rows[1].segments.contains { $0.kind == .incoming && $0.fromLane == 1 })
        XCTAssertTrue(rows[1].segments.contains { $0.kind == .passThrough && $0.fromLane == 0 })

        // B1's parent A is already awaited in lane 1, so B1's lane ends by
        // curving *down* into it — the case that used to be drawn upside down.
        XCTAssertEqual(rows[2].commit.sha, "B1")
        XCTAssertEqual(rows[2].lane, 0)
        XCTAssertTrue(rows[2].segments.contains { $0.kind == .outgoing && $0.fromLane == 0 && $0.toLane == 1 })
        XCTAssertFalse(rows[2].segments.contains { $0.kind == .outgoing && $0.toLane == 0 })

        // A collects both lanes and closes the graph.
        XCTAssertEqual(rows[3].commit.sha, "A")
        XCTAssertEqual(rows[3].lane, 1)
        XCTAssertTrue(rows[3].segments.allSatisfy { $0.kind == .incoming })
        XCTAssertFalse(rows[3].segments.contains { $0.kind == .outgoing })

        assertRowsJoin(rows)
    }

    // MARK: - Octopus Merge

    func testOctopusMergeAllocatesMultipleLanes() {
        let m = commit(sha: "M", parents: ["P1", "P2", "P3"])
        let p1 = commit(sha: "P1", parents: [])
        let p2 = commit(sha: "P2", parents: [])
        let p3 = commit(sha: "P3", parents: [])

        let rows = GitGraphLayout.rows(for: [m, p1, p2, p3])

        XCTAssertEqual(rows.count, 4)
        XCTAssertEqual(rows[0].commit.sha, "M")
        XCTAssertEqual(rows[0].lane, 0)
        XCTAssertGreaterThanOrEqual(rows[0].laneCount, 3)

        // One downward edge per parent, each landing in its own lane.
        let outgoing = rows[0].segments.filter { $0.kind == .outgoing }
        XCTAssertEqual(outgoing.count, 3)
        XCTAssertEqual(Set(outgoing.map(\.toLane)), [0, 1, 2])
        XCTAssertEqual(Set(outgoing.map(\.colorIndex)).count, 3, "sibling lanes must be distinguishable")

        XCTAssertEqual(rows.map(\.lane), [0, 0, 1, 2])
        assertRowsJoin(rows)
    }

    // MARK: - Multiple Roots / Orphan Branch

    func testTwoIndependentRoots() {
        let r1 = commit(sha: "r1", parents: [])
        let r2 = commit(sha: "r2", parents: [])

        let rows = GitGraphLayout.rows(for: [r1, r2])

        XCTAssertEqual(rows.count, 2)
        XCTAssertEqual(rows.map(\.commit.sha), ["r1", "r2"])
        // Neither is waiting on the other, so both start fresh in lane 0 with
        // no edges at all, and the graph never widens.
        XCTAssertEqual(rows.map(\.lane), [0, 0])
        XCTAssertEqual(rows.map(\.laneCount), [1, 1])
        XCTAssertTrue(rows.allSatisfy(\.segments.isEmpty))
    }

    // MARK: - Truncated windows

    func testParentOutsideTheWindowStillLeavesTheRow() {
        // `--max-count` routinely cuts a branch off mid-run; the last row still
        // has to draw its line to the bottom edge or the graph looks severed.
        let head = commit(sha: "head", parents: ["missing"])
        let rows = GitGraphLayout.rows(for: [head])

        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows[0].segments.map(\.kind), [.outgoing])
        XCTAssertEqual(rows[0].laneCount, 1)
    }

    // MARK: - Lane reuse

    func testSideBranchKeepsItsOwnColourUntilTheMergeBase() {
        // A side branch off main, merged back one commit later. Both lanes are
        // live at the same time, so they have to be told apart by colour, and
        // each must keep the same colour for its whole run.
        let m2 = commit(sha: "m2", parents: ["m1", "s1"])
        let s1 = commit(sha: "s1", parents: ["m0"])
        let m1 = commit(sha: "m1", parents: ["m0"])
        let m0 = commit(sha: "m0", parents: [])

        let rows = GitGraphLayout.rows(for: [m2, s1, m1, m0])
        assertRowsJoin(rows)

        XCTAssertEqual(GitGraphLayout.laneCount(of: rows), 2)
        XCTAssertEqual(rows.map(\.lane), [0, 1, 0, 1])

        let mainColor = rows[0].colorIndex
        let sideColor = rows[1].colorIndex
        XCTAssertNotEqual(mainColor, sideColor)
        // m1 is still main; m0 is the merge base, reached along the side lane.
        XCTAssertEqual(rows[2].colorIndex, mainColor)
        XCTAssertEqual(rows[3].colorIndex, sideColor)
    }

    // MARK: - Contract with the palette

    func testColorIndicesStayWithinThePalette() {
        let m = commit(sha: "M", parents: ["P1", "P2", "P3", "P4", "P5"])
        let parents = (1...5).map { commit(sha: "P\($0)", parents: []) }

        let rows = GitGraphLayout.rows(for: [m] + parents)
        let indices = rows.flatMap { [$0.colorIndex] + $0.segments.map(\.colorIndex) }

        XCTAssertTrue(indices.allSatisfy { (0..<GitGraphLayout.colorCount).contains($0) })
    }
}

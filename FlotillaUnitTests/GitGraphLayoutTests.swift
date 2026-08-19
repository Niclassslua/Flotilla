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

    // MARK: - Linear History

    func testLinearHistoryProducesSingleLane() {
        let c3 = commit(sha: "c3", parents: ["c2"])
        let c2 = commit(sha: "c2", parents: ["c1"])
        let c1 = commit(sha: "c1", parents: [])

        let rows = GitGraphLayout.rows(for: [c3, c2, c1])

        XCTAssertEqual(rows.count, 3)
        XCTAssertEqual(rows.map(\.lane), [0, 0, 0])
        XCTAssertEqual(rows.map(\.laneCount), [1, 1, 1])

        // c3 connects down to c2
        XCTAssertEqual(rows[0].segments.count, 1)
        XCTAssertEqual(rows[0].segments[0].kind, .outgoing)
        XCTAssertEqual(rows[0].segments[0].fromLane, 0)
        XCTAssertEqual(rows[0].segments[0].toLane, 0)

        // c2 connects from c3 above and to c1 below
        XCTAssertEqual(rows[1].segments.count, 2)
        XCTAssertEqual(rows[1].segments[0].kind, .incoming)
        XCTAssertEqual(rows[1].segments[1].kind, .outgoing)

        // c1 is root, incoming from c2 above, no downward parent segments
        XCTAssertEqual(rows[2].segments.count, 1)
        XCTAssertEqual(rows[2].segments[0].kind, .incoming)
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

        // M is at lane 0, first parent B1 continues in lane 0, second parent B2 branches to lane 1
        XCTAssertEqual(rows[0].commit.sha, "M")
        XCTAssertEqual(rows[0].lane, 0)
        XCTAssertTrue(rows[0].segments.contains(where: { $0.fromLane == 0 && $0.toLane == 0 && $0.kind == .outgoing }))
        XCTAssertTrue(rows[0].segments.contains(where: { $0.fromLane == 0 && $0.toLane == 1 && $0.kind == .outgoing }))

        // B2 is at lane 1, parent A is not yet in activeLanes, so B2 continues expecting A in lane 1, while B1 passes through in lane 0
        XCTAssertEqual(rows[1].commit.sha, "B2")
        XCTAssertEqual(rows[1].lane, 1)

        // B1 is at lane 0. Its parent A is already expected in lane 1, so B1 merges into lane 1
        XCTAssertEqual(rows[2].commit.sha, "B1")
        XCTAssertEqual(rows[2].lane, 0)

        // A is the root at lane 1 (or 0 after convergence)
        XCTAssertEqual(rows[3].commit.sha, "A")
    }

    // MARK: - Octopus Merge

    func testOctopusMergeAllocatesMultipleLanes() {
        // Merge with 3 parents
        let m = commit(sha: "M", parents: ["P1", "P2", "P3"])
        let p1 = commit(sha: "P1", parents: [])
        let p2 = commit(sha: "P2", parents: [])
        let p3 = commit(sha: "P3", parents: [])

        let rows = GitGraphLayout.rows(for: [m, p1, p2, p3])

        XCTAssertEqual(rows.count, 4)
        XCTAssertEqual(rows[0].commit.sha, "M")
        XCTAssertEqual(rows[0].lane, 0)
        XCTAssertGreaterThanOrEqual(rows[0].laneCount, 3)

        // Must have 3 outgoing segments for P1, P2, and P3
        let outgoings = rows[0].segments.filter { $0.kind == .outgoing }
        XCTAssertEqual(outgoings.count, 3)
    }

    // MARK: - Multiple Roots / Orphan Branch

    func testTwoIndependentRoots() {
        let r1 = commit(sha: "r1", parents: [])
        let r2 = commit(sha: "r2", parents: [])

        let rows = GitGraphLayout.rows(for: [r1, r2])

        XCTAssertEqual(rows.count, 2)
        XCTAssertEqual(rows[0].commit.sha, "r1")
        XCTAssertEqual(rows[1].commit.sha, "r2")
    }
}

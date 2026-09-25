import XCTest
import GitKit

/// Crafted `git log` output, exercised directly rather than only through a
/// real repo — free-form commit bodies, merges without a stat block, and
/// decoration edge cases are all far easier to pin down precisely this way.
final class GitLogParsingTests: XCTestCase {
    private let rs = "\u{1e}"
    private let us = "\u{1f}"

    /// Builds a record in `GitService.logFormat` field order.
    private func record(
        sha: String = "a1b2c3d4e5f6a1b2c3d4e5f6a1b2c3d4e5f6a1b2",
        short: String = "a1b2c3d",
        parents: String = "0000000000000000000000000000000000000000",
        authorName: String = "Niclassslua",
        authorEmail: String = "niclassslua@example.com",
        authorEpoch: String = "1787170585",
        committerName: String = "Niclassslua",
        committerEmail: String = "niclassslua@example.com",
        committerEpoch: String = "1787170585",
        refs: String = "",
        subject: String = "fix(git): drain the pipe",
        tail: String = ""
    ) -> String {
        rs + [
            sha, short, parents,
            authorName, authorEmail, authorEpoch,
            committerName, committerEmail, committerEpoch,
            refs, subject, tail,
        ].joined(separator: us)
    }

    func testParseLogShapes() {
        // Single commit with numstat.
        do {
            let commits = GitService.parseLog(record(tail: "A body line.\n\n40\t12\tCommandRunning.swift\n8\t8\tDiffPanel.swift\n"))
            XCTAssertEqual(commits.count, 1)
            let commit = try! XCTUnwrap(commits.first)
            XCTAssertEqual(commit.shortSHA, "a1b2c3d")
            XCTAssertEqual(commit.subject, "fix(git): drain the pipe")
            XCTAssertEqual(commit.body, "A body line.")
            XCTAssertEqual(commit.stat, GitDiffStat(files: 2, additions: 48, deletions: 20))
            XCTAssertEqual(commit.changedFileCount, 2)
            XCTAssertEqual(commit.authorDate, Date(timeIntervalSince1970: 1_787_170_585))
            XCTAssertFalse(commit.isMerge)
        }

        // Free-form body shares the trailing component with the stat block.
        do {
            let body = "Closes the top three gaps:\n\n- one\ttabbed item\n- two\n\n  indented continuation"
            let commits = GitService.parseLog(record(tail: body + "\n\n5\t1\tfile.swift\n"))
            XCTAssertEqual(commits.first?.body, body)
            XCTAssertEqual(commits.first?.stat, GitDiffStat(files: 1, additions: 5, deletions: 1))
            XCTAssertEqual(commits.first?.changedFileCount, 1)
        }

        XCTAssertEqual(GitService.parseLog(record(tail: "\n\n3\t0\tfile.swift\n")).first?.body, "")

        // Merge: two parents, no numstat block.
        do {
            let commits = GitService.parseLog(record(
                parents: "1111111111111111111111111111111111111111 2222222222222222222222222222222222222222",
                subject: "Merge branch 'feat/settings'",
                tail: ""
            ))
            XCTAssertEqual(commits.first?.parents.count, 2)
            XCTAssertTrue(commits.first?.isMerge ?? false)
            XCTAssertEqual(commits.first?.stat, GitDiffStat(additions: 0, deletions: 0))
            XCTAssertEqual(commits.first?.changedFileCount, 0)
        }

        do {
            let commits = GitService.parseLog(record(parents: "", tail: "\n\n1\t0\ta.txt\n"))
            XCTAssertEqual(commits.first?.parents, [])
            XCTAssertFalse(commits.first?.isMerge ?? true)
        }

        do {
            let commits = GitService.parseLog(record(tail: "\n\n-\t-\timage.png\n4\t2\tcode.swift\n"))
            XCTAssertEqual(commits.first?.stat, GitDiffStat(files: 1, additions: 4, deletions: 2), "numstat can't parse the binary line")
            XCTAssertEqual(commits.first?.changedFileCount, 2, "a binary file still changed")
        }

        do {
            let raw = record(short: "aaa1111", subject: "first", tail: "\n\n1\t0\ta.txt\n")
                + record(short: "bbb2222", subject: "second", tail: "\n\n2\t0\tb.txt\n")
            let commits = GitService.parseLog(raw)
            XCTAssertEqual(commits.map(\.shortSHA), ["aaa1111", "bbb2222"])
            XCTAssertEqual(commits.map(\.subject), ["first", "second"])
        }

        XCTAssertEqual(GitService.parseLog(rs + "not-enough" + us + "fields").count, 0)
        XCTAssertEqual(GitService.parseLog("").count, 0)

        XCTAssertFalse(GitService.parseLog(record()).first?.hasDistinctCommitter ?? true)
        XCTAssertTrue(
            GitService.parseLog(record(committerName: "GitHub", committerEmail: "noreply@github.com")).first?.hasDistinctCommitter ?? false
        )
    }
}

/// `--decorate=full` is used specifically so a slashed local branch can't be
/// mistaken for a remote one; these lock that in.
final class GitRefDecorationParsingTests: XCTestCase {
    func testParseRefsShapes() {
        XCTAssertEqual(
            GitService.parseRefs("HEAD -> refs/heads/main, refs/remotes/origin/main, tag: refs/tags/v1.0"),
            [
                GitCommitRef(name: "HEAD", kind: .head),
                GitCommitRef(name: "main", kind: .localBranch),
                GitCommitRef(name: "origin/main", kind: .remoteBranch),
                GitCommitRef(name: "v1.0", kind: .tag),
            ]
        )
        XCTAssertEqual(
            GitService.parseRefs("HEAD -> refs/heads/fix/tmux-status-line").last,
            GitCommitRef(name: "fix/tmux-status-line", kind: .localBranch)
        )
        XCTAssertEqual(GitService.parseRefs("HEAD"), [GitCommitRef(name: "HEAD", kind: .head)])
        XCTAssertEqual(GitService.parseRefs(""), [])
    }
}

final class GitNameStatusParsingTests: XCTestCase {
    func testParseNameStatusShapes() {
        let kinds = GitService.parseNameStatus("A\tnew.swift\nM\tchanged.swift\nD\tgone.swift\nT\ttyped.swift\n")
        XCTAssertEqual(kinds.map(\.path), ["new.swift", "changed.swift", "gone.swift", "typed.swift"])
        XCTAssertEqual(kinds.map(\.kind), [.added, .modified, .deleted, .typeChanged])
        XCTAssertTrue(kinds.allSatisfy { $0.previousPath == nil })

        // Similarity score rides with the marker; the *new* path is identity.
        let renamed = GitService.parseNameStatus("R100\ta.txt\trenamed.txt\n")
        XCTAssertEqual(renamed.first?.path, "renamed.txt")
        XCTAssertEqual(renamed.first?.previousPath, "a.txt")
        XCTAssertEqual(renamed.first?.kind, .renamed)

        let copied = GitService.parseNameStatus("C75\tsource.txt\tcopy.txt\n")
        XCTAssertEqual(copied.first?.kind, .copied)
        XCTAssertEqual(copied.first?.previousPath, "source.txt")

        XCTAssertEqual(GitService.parseNameStatus("garbage\nA\tok.swift\n").map(\.path), ["ok.swift"])
    }
}

/// Pure remote-shape normalization — no repository required.
final class GitCommitWebURLTests: XCTestCase {
    private let sha = "a1b2c3d"

    func testWebURLNormalization() {
        let cases: [(remote: String, sha: String, expected: String?)] = [
            ("git@github.com:Niclassslua/Flotilla.git", sha, "https://github.com/Niclassslua/Flotilla/commit/a1b2c3d"),
            ("ssh://git@github.com/Niclassslua/Flotilla.git", sha, "https://github.com/Niclassslua/Flotilla/commit/a1b2c3d"),
            ("https://github.com/Niclassslua/Flotilla.git", sha, "https://github.com/Niclassslua/Flotilla/commit/a1b2c3d"),
            ("https://github.com/Niclassslua/Flotilla", sha, "https://github.com/Niclassslua/Flotilla/commit/a1b2c3d"),
            ("git@gitlab.com:group/project.git", sha, "https://gitlab.com/group/project/commit/a1b2c3d"),
            ("/Users/dev/repos/thing.git", sha, nil),
            ("", sha, nil),
            ("git@github.com:o/r.git", "", nil),
        ]
        for entry in cases {
            XCTAssertEqual(
                GitService.webURL(forRemote: entry.remote, commitSHA: entry.sha)?.absoluteString,
                entry.expected,
                entry.remote
            )
        }
    }
}

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

    func testParsesSingleCommitWithStatBlock() {
        let raw = record(tail: "A body line.\n\n40\t12\tCommandRunning.swift\n8\t8\tDiffPanel.swift\n")
        let commits = GitService.parseLog(raw)

        XCTAssertEqual(commits.count, 1)
        let commit = try? XCTUnwrap(commits.first)
        XCTAssertEqual(commit?.shortSHA, "a1b2c3d")
        XCTAssertEqual(commit?.subject, "fix(git): drain the pipe")
        XCTAssertEqual(commit?.body, "A body line.")
        XCTAssertEqual(commit?.stat, GitDiffStat(additions: 48, deletions: 20))
        XCTAssertEqual(commit?.changedFileCount, 2)
        XCTAssertEqual(commit?.authorDate, Date(timeIntervalSince1970: 1_787_170_585))
        XCTAssertFalse(commit?.isMerge ?? true)
    }

    /// The body is free-form and lands in the same trailing component as the
    /// stat block, so this is the parse most at risk of desynchronizing.
    func testMultiLineBodyWithBlankLinesAndTabsSurvives() {
        let body = "Closes the top three gaps:\n\n- one\ttabbed item\n- two\n\n  indented continuation"
        let raw = record(tail: body + "\n\n5\t1\tfile.swift\n")
        let commits = GitService.parseLog(raw)

        XCTAssertEqual(commits.first?.body, body)
        XCTAssertEqual(commits.first?.stat, GitDiffStat(additions: 5, deletions: 1))
        XCTAssertEqual(commits.first?.changedFileCount, 1)
    }

    func testEmptyBodyYieldsEmptyStringNotWhitespace() {
        let commits = GitService.parseLog(record(tail: "\n\n3\t0\tfile.swift\n"))
        XCTAssertEqual(commits.first?.body, "")
    }

    /// Plain `git log --numstat` emits no stat block for a merge.
    func testMergeCommitHasTwoParentsAndNoStat() {
        let raw = record(
            parents: "1111111111111111111111111111111111111111 2222222222222222222222222222222222222222",
            subject: "Merge branch 'feat/settings'",
            tail: ""
        )
        let commits = GitService.parseLog(raw)

        XCTAssertEqual(commits.first?.parents.count, 2)
        XCTAssertTrue(commits.first?.isMerge ?? false)
        XCTAssertEqual(commits.first?.stat, GitDiffStat(additions: 0, deletions: 0))
        XCTAssertEqual(commits.first?.changedFileCount, 0)
    }

    func testRootCommitHasNoParents() {
        let commits = GitService.parseLog(record(parents: "", tail: "\n\n1\t0\ta.txt\n"))
        XCTAssertEqual(commits.first?.parents, [])
        XCTAssertFalse(commits.first?.isMerge ?? true)
    }

    func testBinaryFileCountsAsChangedButContributesNoLines() {
        let commits = GitService.parseLog(record(tail: "\n\n-\t-\timage.png\n4\t2\tcode.swift\n"))
        XCTAssertEqual(commits.first?.stat, GitDiffStat(additions: 4, deletions: 2))
        XCTAssertEqual(commits.first?.changedFileCount, 2, "a binary file still changed")
    }

    func testParsesMultipleRecords() {
        let raw = record(short: "aaa1111", subject: "first", tail: "\n\n1\t0\ta.txt\n")
            + record(short: "bbb2222", subject: "second", tail: "\n\n2\t0\tb.txt\n")
        let commits = GitService.parseLog(raw)

        XCTAssertEqual(commits.map(\.shortSHA), ["aaa1111", "bbb2222"])
        XCTAssertEqual(commits.map(\.subject), ["first", "second"])
    }

    func testMalformedRecordIsSkippedRatherThanCrashing() {
        XCTAssertEqual(GitService.parseLog(rs + "not-enough" + us + "fields").count, 0)
        XCTAssertEqual(GitService.parseLog("").count, 0)
    }

    func testDistinctCommitterIsDetected() {
        let same = GitService.parseLog(record()).first
        XCTAssertFalse(same?.hasDistinctCommitter ?? true)

        let rebased = GitService.parseLog(
            record(committerName: "GitHub", committerEmail: "noreply@github.com")
        ).first
        XCTAssertTrue(rebased?.hasDistinctCommitter ?? false)
    }
}

/// `--decorate=full` is used specifically so a slashed local branch can't be
/// mistaken for a remote one; these lock that in.
final class GitRefDecorationParsingTests: XCTestCase {
    func testParsesHeadBranchRemoteAndTag() {
        let refs = GitService.parseRefs(
            "HEAD -> refs/heads/main, refs/remotes/origin/main, tag: refs/tags/v1.0"
        )
        XCTAssertEqual(refs, [
            GitCommitRef(name: "HEAD", kind: .head),
            GitCommitRef(name: "main", kind: .localBranch),
            GitCommitRef(name: "origin/main", kind: .remoteBranch),
            GitCommitRef(name: "v1.0", kind: .tag),
        ])
    }

    func testSlashedLocalBranchIsNotMistakenForRemote() {
        let refs = GitService.parseRefs("HEAD -> refs/heads/fix/tmux-status-line")
        XCTAssertEqual(refs.last, GitCommitRef(name: "fix/tmux-status-line", kind: .localBranch))
    }

    func testDetachedHeadAndEmptyDecoration() {
        XCTAssertEqual(GitService.parseRefs("HEAD"), [GitCommitRef(name: "HEAD", kind: .head)])
        XCTAssertEqual(GitService.parseRefs(""), [])
    }
}

final class GitNameStatusParsingTests: XCTestCase {
    func testParsesEachChangeKind() {
        let raw = "A\tnew.swift\nM\tchanged.swift\nD\tgone.swift\nT\ttyped.swift\n"
        let changes = GitService.parseNameStatus(raw)

        XCTAssertEqual(changes.map(\.path), ["new.swift", "changed.swift", "gone.swift", "typed.swift"])
        XCTAssertEqual(changes.map(\.kind), [.added, .modified, .deleted, .typeChanged])
        XCTAssertTrue(changes.allSatisfy { $0.previousPath == nil })
    }

    /// The similarity score rides along with the marker (`R100`), and the
    /// *new* path is the identity — the old one is provenance.
    func testRenameKeepsBothPaths() {
        let changes = GitService.parseNameStatus("R100\ta.txt\trenamed.txt\n")
        XCTAssertEqual(changes.first?.path, "renamed.txt")
        XCTAssertEqual(changes.first?.previousPath, "a.txt")
        XCTAssertEqual(changes.first?.kind, .renamed)
    }

    func testCopyIsDistinguishedFromRename() {
        let changes = GitService.parseNameStatus("C75\tsource.txt\tcopy.txt\n")
        XCTAssertEqual(changes.first?.kind, .copied)
        XCTAssertEqual(changes.first?.previousPath, "source.txt")
    }

    func testUnparseableLinesAreSkipped() {
        XCTAssertEqual(GitService.parseNameStatus("garbage\nA\tok.swift\n").map(\.path), ["ok.swift"])
    }
}

/// Pure remote-shape normalization — no repository required.
final class GitCommitWebURLTests: XCTestCase {
    private let sha = "a1b2c3d"

    func testSCPStyleSSHRemote() {
        XCTAssertEqual(
            GitService.webURL(forRemote: "git@github.com:Niclassslua/Flotilla.git", commitSHA: sha)?.absoluteString,
            "https://github.com/Niclassslua/Flotilla/commit/a1b2c3d"
        )
    }

    func testSSHProtocolRemote() {
        XCTAssertEqual(
            GitService.webURL(forRemote: "ssh://git@github.com/Niclassslua/Flotilla.git", commitSHA: sha)?.absoluteString,
            "https://github.com/Niclassslua/Flotilla/commit/a1b2c3d"
        )
    }

    func testHTTPSRemoteWithAndWithoutGitSuffix() {
        XCTAssertEqual(
            GitService.webURL(forRemote: "https://github.com/Niclassslua/Flotilla.git", commitSHA: sha)?.absoluteString,
            "https://github.com/Niclassslua/Flotilla/commit/a1b2c3d"
        )
        XCTAssertEqual(
            GitService.webURL(forRemote: "https://github.com/Niclassslua/Flotilla", commitSHA: sha)?.absoluteString,
            "https://github.com/Niclassslua/Flotilla/commit/a1b2c3d"
        )
    }

    func testNonGitHubHostStillResolves() {
        XCTAssertEqual(
            GitService.webURL(forRemote: "git@gitlab.com:group/project.git", commitSHA: sha)?.absoluteString,
            "https://gitlab.com/group/project/commit/a1b2c3d"
        )
    }

    /// A local-path remote has no web presence — callers hide the affordance.
    func testLocalPathRemoteReturnsNil() {
        XCTAssertNil(GitService.webURL(forRemote: "/Users/dev/repos/thing.git", commitSHA: sha))
        XCTAssertNil(GitService.webURL(forRemote: "", commitSHA: sha))
    }

    func testEmptySHAReturnsNil() {
        XCTAssertNil(GitService.webURL(forRemote: "git@github.com:o/r.git", commitSHA: ""))
    }
}

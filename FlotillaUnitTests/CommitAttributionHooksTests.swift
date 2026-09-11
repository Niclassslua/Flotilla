import XCTest
import GitKit
import ProcessKit
import PersistenceKit
import SessionKit
import SettingsKit
@testable import Flotilla

/// A disposable repository whose git runs the way an agent session's does —
/// through the attribution hooks — or the way the user's own shell does,
/// without them. Isolated from the machine's global git configuration and
/// from any Flotilla agent environment the test process inherited.
final class AttributionGitSandbox {
    let root: URL
    let repo: URL
    let support: URL
    let sessionID = UUID()
    private let runner = ProcessCommandRunner()

    var hooksDirectory: URL { support.appendingPathComponent("githooks", isDirectory: true) }
    var payloadDirectory: URL {
        support.appendingPathComponent("attribution", isDirectory: true)
            .appendingPathComponent(sessionID.uuidString, isDirectory: true)
    }

    init() async throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("flotilla-attribution-\(UUID().uuidString)", isDirectory: true)
        repo = root.appendingPathComponent("repo", isDirectory: true)
        support = root.appendingPathComponent("support", isDirectory: true)
        try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
        try CommitAttributionHooks().prepare(directory: hooksDirectory)

        try await user(["init", "-q", "-b", "main"])
        try write("README.md", "base\n")
        try await user(["add", "README.md"])
        try await user(["commit", "-q", "-m", "base"])
    }

    func remove() {
        try? FileManager.default.removeItem(at: root)
    }

    func writePayload(_ mode: CommitAttributionHookMode, model: String? = "opus") throws {
        try CommitAttributionPayload.write(
            CommitAttributionSessionInfo(
                sessionID: sessionID,
                projectID: nil,
                agent: "claudeCode",
                model: model,
                title: "Parser cleanup",
                prompt: "Tidy up the parser.",
                createdAt: Date(timeIntervalSince1970: 1_700_000_000)
            ),
            mode: mode,
            to: payloadDirectory
        )
    }

    /// git as an agent session runs it.
    @discardableResult
    func agent(_ arguments: [String], authorDate: String? = nil) async throws -> CommandResult {
        var base = Self.isolatedEnvironment
        if let authorDate {
            base["GIT_AUTHOR_DATE"] = authorDate
        }
        let environment = CommitAttributionHooks.environment(
            base: base,
            sessionID: sessionID.uuidString,
            attributionDirectory: payloadDirectory,
            flotillaHooksDirectory: hooksDirectory,
            originalHooksDirectory: nil
        )
        return try await git(arguments, environment: environment)
    }

    /// git as the user runs it in their own shell: no Flotilla hooks.
    @discardableResult
    func user(_ arguments: [String]) async throws -> CommandResult {
        try await git(arguments, environment: Self.isolatedEnvironment)
    }

    func write(_ file: String, _ contents: String) throws {
        try contents.write(to: repo.appendingPathComponent(file), atomically: true, encoding: .utf8)
    }

    func sha(_ revision: String = "HEAD") async throws -> String {
        try await user(["rev-parse", revision]).stdout.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// The attribution markers a commit adds.
    func markersAdded(by revision: String = "HEAD") async throws -> [String] {
        try await user([
            "diff-tree", "--root", "--no-commit-id", "--no-renames", "--name-only", "-r",
            "--diff-filter=A", revision, "--", CommitAttributionHooks.sharedDirectory,
        ]).stdout.split(separator: "\n").map(String.init).filter { $0.contains("/m-") }
    }

    func trackedFiles(under path: String = ".flotilla") async throws -> [String] {
        try await user(["ls-files", "--", path]).stdout.split(separator: "\n").map(String.init)
    }

    func status() async throws -> String {
        try await user(["status", "--porcelain"]).stdout
    }

    func installRepositoryHook(_ name: String, script: String) throws {
        let hook = repo.appendingPathComponent(".git/hooks/\(name)")
        try script.write(to: hook, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: hook.path)
    }

    private func git(_ arguments: [String], environment: [String: String]) async throws -> CommandResult {
        try await runner.run(
            ["git"] + arguments,
            executable: URL(fileURLWithPath: "/usr/bin/env"),
            workingDirectory: repo,
            environment: environment
        )
    }

    private static let isolatedEnvironment: [String: String] = [
        "GIT_CONFIG_GLOBAL": "/dev/null",
        "GIT_CONFIG_NOSYSTEM": "1",
        // Drops a core.hooksPath inherited from an outer agent session.
        "GIT_CONFIG_COUNT": "0",
        "GIT_AUTHOR_NAME": "Flotilla Tests",
        "GIT_AUTHOR_EMAIL": "flotilla-tests@example.com",
        "GIT_COMMITTER_NAME": "Flotilla Tests",
        "GIT_COMMITTER_EMAIL": "flotilla-tests@example.com",
        "GIT_EDITOR": "true",
        "FLOTILLA_ATTRIBUTION_DIR": "",
        "FLOTILLA_SESSION": "",
        "FLOTILLA_ORIGINAL_HOOKS": "",
    ]
}

final class CommitAttributionHooksTests: XCTestCase {
    private var sandbox: AttributionGitSandbox!

    override func setUp() async throws {
        try await super.setUp()
        sandbox = try await AttributionGitSandbox()
    }

    override func tearDown() async throws {
        sandbox.remove()
        try await super.tearDown()
    }

    /// If an agent commit didn't add its own marker, a squash or rebase would
    /// lose which session made it; if old markers stayed, every commit would
    /// leave a file in the project forever.
    func testSharedCommitsEachAddOneMarkerWhileTheTreeKeepsOnlyTheLatest() async throws {
        try sandbox.writePayload(.shared)

        try sandbox.write("a.txt", "a\n")
        try await sandbox.agent(["add", "a.txt"])
        let first = try await sandbox.agent(["commit", "-q", "-m", "first"])
        XCTAssertEqual(first.exitCode, 0, first.stderr)
        try sandbox.write("b.txt", "b\n")
        try await sandbox.agent(["add", "b.txt"])
        try await sandbox.agent(["commit", "-q", "-m", "second"])

        let firstMarkers = try await sandbox.markersAdded(by: "HEAD~1")
        let secondMarkers = try await sandbox.markersAdded()
        XCTAssertEqual(firstMarkers.count, 1)
        XCTAssertEqual(secondMarkers.count, 1)
        XCTAssertNotEqual(firstMarkers, secondMarkers)
        let marker = secondMarkers.first.flatMap(CommitAttributionMarker.init(path:))
        XCTAssertEqual(marker?.sessionID, sandbox.sessionID)
        XCTAssertEqual(marker?.agent, "claudeCode")
        XCTAssertEqual(marker?.modelSlug, "opus")

        let tracked = try await sandbox.trackedFiles()
        XCTAssertEqual(tracked.filter { $0.contains("/m-") }, secondMarkers, "only the newest marker stays in the tree")
        let document = try await sandbox.user(["show", "HEAD:\(CommitAttributionMarker.promptDocumentPath(for: sandbox.sessionID))"]).stdout
        XCTAssertEqual(CommitAttributionPromptDocument.parse(document)?.prompt, "Tidy up the parser.")
        let status = try await sandbox.status()
        XCTAssertEqual(status, "")
    }

    /// Bypassing hooks must not rewrite history. A pathspec commit still
    /// needs its real index aligned with the marker in the committed tree.
    func testSharedNoVerifyDoesNotAmendAndPathspecCommitKeepsIndexClean() async throws {
        try sandbox.writePayload(.shared)

        try sandbox.write("a.txt", "a\n")
        try await sandbox.agent(["add", "a.txt"])
        try await sandbox.agent(["commit", "-q", "--no-verify", "-m", "skip hooks"])
        let noVerifyMarkers = try await sandbox.markersAdded()
        XCTAssertTrue(noVerifyMarkers.isEmpty, "bypassing pre-commit must not trigger a hidden amend")

        try sandbox.write("README.md", "changed\n")
        try await sandbox.agent(["commit", "-q", "-m", "pathspec", "README.md"])
        let pathspecMarkers = try await sandbox.markersAdded()
        XCTAssertEqual(pathspecMarkers.count, 1)
        let status = try await sandbox.status()
        XCTAssertEqual(status, "", "the real index must match what was committed")
    }

    /// A repository's own pre-commit check must still block a commit, and the
    /// blocked commit must not leave attribution files staged behind.
    func testFailingRepositoryPreCommitAbortsBeforeAnyMarkerIsStaged() async throws {
        try sandbox.writePayload(.shared)
        try sandbox.installRepositoryHook("pre-commit", script: "#!/bin/sh\nexit 1\n")

        try sandbox.write("a.txt", "a\n")
        try await sandbox.agent(["add", "a.txt"])
        let result = try await sandbox.agent(["commit", "-q", "-m", "blocked"])

        XCTAssertNotEqual(result.exitCode, 0)
        let staged = try await sandbox.user(["diff", "--cached", "--name-only"]).stdout
        XCTAssertEqual(staged, "a.txt\n")
    }

    /// Dropping a commit in a rebase and squash-merging a branch are everyday
    /// edits; markers must never turn them into conflicts, and each commit must
    /// keep a marker through them.
    func testDroppingMiddleCommitAndSquashingPreserveMarker() async throws {
        try sandbox.writePayload(.shared)
        try await sandbox.user(["switch", "-q", "-c", "feature"])
        for name in ["one", "two", "three"] {
            try sandbox.write("\(name).txt", "\(name)\n")
            try await sandbox.agent(["add", "\(name).txt"])
            try await sandbox.agent(["commit", "-q", "-m", name])
        }
        let featureTip = try await sandbox.sha()

        let drop = try await sandbox.user(["rebase", "-q", "--onto", "HEAD~2", "HEAD~1"])
        XCTAssertEqual(drop.exitCode, 0, drop.stderr)
        let replayedMarkers = try await sandbox.markersAdded()
        XCTAssertEqual(replayedMarkers.count, 1, "the replayed commit still adds its own marker")

        try await sandbox.user(["switch", "-q", "main"])
        let merge = try await sandbox.user(["merge", "-q", "--squash", featureTip])
        XCTAssertEqual(merge.exitCode, 0, merge.stderr)
        try await sandbox.user(["commit", "-q", "-m", "squash"])
        let squashMarkers = try await sandbox.markersAdded()
        XCTAssertEqual(squashMarkers.count, 1, "a squash carries the session's latest marker")
    }

    /// An agent replaying someone else's commit must not claim it.
    func testAgentCherryPickDoesNotStampTheCopiedCommit() async throws {
        try sandbox.writePayload(.shared)
        try await sandbox.user(["switch", "-q", "-c", "human"])
        try sandbox.write("human.txt", "human\n")
        try await sandbox.user(["add", "human.txt"])
        try await sandbox.user(["commit", "-q", "-m", "human work"])
        let humanCommit = try await sandbox.sha()
        try await sandbox.user(["switch", "-q", "main"])

        let pick = try await sandbox.agent(["cherry-pick", humanCommit])

        XCTAssertEqual(pick.exitCode, 0, pick.stderr)
        let markers = try await sandbox.markersAdded()
        XCTAssertTrue(markers.isEmpty)
        let status = try await sandbox.status()
        XCTAssertEqual(status, "")
    }

    /// On this Mac must record the commit and where an amend moved it, and
    /// must write nothing into the repository.
    func testLocalModeSpoolsCommitAndAmendWithoutTouchingTheRepository() async throws {
        try sandbox.writePayload(.local)
        try sandbox.write("a.txt", "a\n")
        try await sandbox.agent(["add", "a.txt"])
        try await sandbox.agent(["commit", "-q", "-m", "local"])
        let original = try await sandbox.sha()
        try await sandbox.agent(["commit", "-q", "--amend", "-m", "local, reworded"])
        let amended = try await sandbox.sha()

        let events = CommitAttributionPayload.claimEvents(in: sandbox.payloadDirectory).events
        let commits = events.compactMap { event -> CommitAttributionEvent.Commit? in
            if case .commit(let commit) = event { return commit }
            return nil
        }
        let rewrites = events.compactMap { event -> CommitAttributionEvent.Rewrite? in
            if case .rewrite(let rewrite) = event { return rewrite }
            return nil
        }
        XCTAssertEqual(commits.first?.sha, original)
        XCTAssertEqual(commits.first?.authorEmail, "flotilla-tests@example.com")
        XCTAssertEqual(commits.first?.model, "opus")
        XCTAssertEqual(commits.first?.sessionInfo?.prompt, "Tidy up the parser.")
        XCTAssertEqual(rewrites.count, 1)
        XCTAssertEqual(rewrites.first?.kind, "amend")
        XCTAssertEqual(rewrites.first?.pairs.map(\.old), [original])
        XCTAssertEqual(rewrites.first?.pairs.map(\.new), [amended])
        XCTAssertEqual(rewrites.first?.commonDirectory, commits.first?.commonDirectory)
        let tracked = try await sandbox.trackedFiles()
        XCTAssertTrue(tracked.isEmpty)
    }

    /// Off must record nothing, while the repository's own hooks keep running.
    func testOffModeRecordsNothingButStillRunsRepositoryHooks() async throws {
        try sandbox.writePayload(.off)
        let ran = sandbox.root.appendingPathComponent("post-commit-ran")
        try sandbox.installRepositoryHook("post-commit", script: "#!/bin/sh\ntouch '\(ran.path)'\n")

        try sandbox.write("a.txt", "a\n")
        try await sandbox.agent(["add", "a.txt"])
        try await sandbox.agent(["commit", "-q", "-m", "off"])

        XCTAssertTrue(FileManager.default.fileExists(atPath: ran.path), "the repository's post-commit must still run")
        let tracked = try await sandbox.trackedFiles()
        XCTAssertTrue(tracked.isEmpty)
        XCTAssertTrue(CommitAttributionPayload.claimEvents(in: sandbox.payloadDirectory).events.isEmpty)
    }
}

@MainActor
final class CommitAttributionPersistenceTests: XCTestCase {
    func testLegacySettingsMigrateWithoutEnablingSharing() throws {
        let decoder = JSONDecoder()
        let disabled = try decoder.decode(GitPreferences.self, from: Data(#"{"stampAgentTrailer":false}"#.utf8))
        let enabled = try decoder.decode(GitPreferences.self, from: Data(#"{"stampAgentTrailer":true}"#.utf8))
        XCTAssertEqual(disabled.defaultCommitAttribution, .off)
        XCTAssertEqual(enabled.defaultCommitAttribution, .local)
        XCTAssertEqual(try decoder.decode(GitPreferences.self, from: JSONEncoder().encode(enabled)), enabled)
    }

    func testLocalIngestionIsIdempotentAndFollowsExplicitRewrite() async throws {
        let sandbox = try await AttributionGitSandbox()
        defer { sandbox.remove() }
        try sandbox.writePayload(.local)
        try sandbox.write("change.txt", "change\n")
        try await sandbox.agent(["add", "change.txt"])
        let made = try await sandbox.agent(["commit", "-q", "-m", "original"])
        XCTAssertEqual(made.exitCode, 0, made.stderr)
        let original = try await sandbox.sha()
        let repository = try GRDBSessionRepository()
        let git = GitService()
        let service = CommitAttributionService(repository: repository, gitService: git,
            settingsProvider: { AppSettings() }, supportDirectory: sandbox.support)
        await service.ingestPendingEvents()
        await service.ingestPendingEvents()
        let resolvedKey = try await git.commonGitDirectory(at: sandbox.repo)
        let key = try XCTUnwrap(resolvedKey)
        XCTAssertEqual(try repository.loadAttributedCommits(repositoryKey: key).count, 1)
        let amended = try await sandbox.agent(["commit", "-q", "--amend", "-m", "changed message"])
        XCTAssertEqual(amended.exitCode, 0, amended.stderr)
        let newSHA = try await sandbox.sha()
        XCTAssertNotEqual(original, newSHA)
        let result = await service.attributions(forCommits: [newSHA], repoPath: sandbox.repo, sessions: [])
        XCTAssertEqual(result[newSHA]?.prompt, "Tidy up the parser.")
        XCTAssertEqual(result[newSHA]?.model, "opus")
        let oldRecord = try XCTUnwrap(repository.loadAttributedCommits(repositoryKey: key).first { $0.originalSHA == original })
        XCTAssertTrue(try repository.loadAttributedCommitLinks(repositoryKey: key).contains {
            $0.commitID == oldRecord.id && $0.sha == newSHA && $0.source == .rewrite
        })
    }

    func testRevertDoesNotClaimTheRestoredMarkerAsNewAttribution() async throws {
        let sandbox = try await AttributionGitSandbox()
        defer { sandbox.remove() }
        try sandbox.writePayload(.shared)
        for value in ["first", "second"] {
            try sandbox.write("change.txt", value + "\n")
            try await sandbox.agent(["add", "change.txt"])
            let commit = try await sandbox.agent(["commit", "-q", "-m", value])
            XCTAssertEqual(commit.exitCode, 0, commit.stderr)
        }
        let revert = try await sandbox.user(["revert", "--no-edit", "HEAD"])
        XCTAssertEqual(revert.exitCode, 0, revert.stderr)
        let sha = try await sandbox.sha()
        let markers = try await GitService().addedAttributionMarkers(forCommits: [sha], at: sandbox.repo)
        XCTAssertNil(markers[sha])
    }

    func testExternalRewriteRequiresMatchingPatchNotJustAuthorTimestamp() async throws {
        let sandbox = try await AttributionGitSandbox()
        defer { sandbox.remove() }
        try sandbox.writePayload(.local)
        try sandbox.write("change.txt", "original change\n")
        try await sandbox.agent(["add", "change.txt"])
        let made = try await sandbox.agent(["commit", "-q", "-m", "original"])
        XCTAssertEqual(made.exitCode, 0, made.stderr)
        let repository = try GRDBSessionRepository()
        let service = CommitAttributionService(repository: repository, gitService: GitService(),
            settingsProvider: { AppSettings() }, supportDirectory: sandbox.support)
        await service.ingestPendingEvents()
        // A message-only rewrite outside Flotilla has the same patch.
        let reword = try await sandbox.user(["commit", "-q", "--amend", "-m", "reworded outside app"])
        XCTAssertEqual(reword.exitCode, 0, reword.stderr)
        let reworded = try await sandbox.sha()
        let matched = await service.attributions(forCommits: [reworded], repoPath: sandbox.repo, sessions: [])
        XCTAssertEqual(matched[reworded]?.prompt, "Tidy up the parser.")
        // A different patch retains exactly the same author/email/time on amend.
        try sandbox.write("change.txt", "different work\n")
        try await sandbox.user(["add", "change.txt"])
        let changed = try await sandbox.user(["commit", "-q", "--amend", "-m", "different patch"])
        XCTAssertEqual(changed.exitCode, 0, changed.stderr)
        let changedSHA = try await sandbox.sha()
        let unmatched = await service.attributions(forCommits: [changedSHA], repoPath: sandbox.repo, sessions: [])
        XCTAssertNil(unmatched[changedSHA], "same author and timestamp must not attach a prompt to unrelated work")
    }

    func testOneSessionRetainsIndependentSnapshotsAcrossRepositories() throws {
        let repository = try GRDBSessionRepository()
        let sessionID = UUID()
        for key in ["repository-a", "repository-b"] {
            try repository.saveAttributionSession(AttributionSessionSnapshot(
                sessionID: sessionID, projectID: nil, repositoryKey: key,
                agent: .claudeCode, model: "opus", title: key, prompt: "Prompt for " + key,
                combinedPatchID: nil, createdAt: Date()
            ))
            let commit = AttributedCommit(
                sessionID: sessionID, repositoryKey: key, authorEmail: "author@example.com",
                authorTime: 100, patchID: nil, originalSHA: key, agent: .claudeCode,
                model: "opus", recordedAt: Date()
            )
            try repository.saveAttributedCommits([commit], links: [
                AttributedCommitLink(commitID: commit.id, sha: key, source: .recorded, verifiedAt: Date())
            ])
        }
        // No live Session is necessary: attribution has an independent lifetime.
        try repository.delete(sessionID: sessionID)
        for key in ["repository-a", "repository-b"] {
            XCTAssertEqual(try repository.loadAttributionSessions(repositoryKey: key).first?.prompt, "Prompt for " + key)
            XCTAssertEqual(try repository.loadAttributedCommits(repositoryKey: key).count, 1)
            XCTAssertEqual(try repository.loadAttributedCommitLinks(repositoryKey: key).count, 1)
        }
        try repository.deleteAllCommitAttribution()
        XCTAssertTrue(try repository.loadAttributedCommits(repositoryKey: "repository-a").isEmpty)
        XCTAssertTrue(try repository.loadAttributedCommitLinks(repositoryKey: "repository-b").isEmpty)
    }

    func testPromptDocumentPreservesTrailingNewlines() throws {
        for prompt in ["prompt", "prompt\n", "prompt\n\n", ""] {
            let info = CommitAttributionSessionInfo(sessionID: UUID(), projectID: nil,
                agent: "claudeCode", model: nil, title: "Title", prompt: prompt, createdAt: Date())
            XCTAssertEqual(CommitAttributionPromptDocument.parse(CommitAttributionPromptDocument.render(info))?.prompt, prompt)
        }
    }

    func testOffPayloadDoesNotWritePromptOrProvider() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let info = CommitAttributionSessionInfo(sessionID: UUID(), projectID: nil,
            agent: "claudeCode", model: "opus", title: "Private", prompt: "Private prompt", createdAt: Date())
        try CommitAttributionPayload.write(info, mode: .off, to: directory)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path), ["mode"])
    }

    func testUnpublishedEventIsNotConsumed() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let pending = directory.appendingPathComponent("event.pending")
        try Data("partial".utf8).write(to: pending)
        let claim = CommitAttributionPayload.claimEvents(in: directory)
        claim.complete()
        XCTAssertTrue(claim.events.isEmpty)
        XCTAssertTrue(FileManager.default.fileExists(atPath: pending.path))
    }
}

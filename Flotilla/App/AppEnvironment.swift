import Foundation
import SessionKit
import PersistenceKit
import GitKit
import ProcessKit

/// Assembles the app's protocol-typed services. `UI_TESTING=1` swaps in an
/// in-memory repository seeded with fixture data so UI tests never touch
/// the real database. `gitService` is always the real `GitService` —
/// unlike the session repository/process layer, git operations are safe to
/// run for real in tests since they only ever touch paths the app itself
/// controls, and the diff panel needs to reflect real file changes.
@MainActor
final class AppEnvironment {
    /// Fixed path `CreateSessionView.chooseFolder()` substitutes for the
    /// NSOpenPanel under `UI_TESTING=1`. Reset to a fresh one-commit repo
    /// on every launch by this same (unsandboxed) app process — the
    /// XCUITest runner process is sandboxed read-only outside its own
    /// container by an Xcode-applied default that isn't overridable via
    /// project settings, so test code itself cannot write fixture files;
    /// only the app process can.
    static let uiTestFixtureProjectPath = URL(fileURLWithPath: "/tmp/flotilla-uitest-project")
    static let uiTestWorktreeBasePath = URL(fileURLWithPath: "/tmp/flotilla-uitest-worktrees")

    let sessionRepository: SessionRepository
    let gitService: GitServiceProtocol
    /// `nil` when the GitHub CLI isn't installed — PR creation is hidden
    /// rather than shown disabled, since `Settings` already surfaces `gh`'s
    /// found/missing status.
    let ghService: GhServiceProtocol?
    let worktreeBaseDirectory: URL
    let isUITesting: Bool
    /// `FLOTILLA_DEMO_DATA=1`: run on a throwaway in-memory database seeded
    /// with a fleet covering every status, waiting reason, and agent. Used to
    /// review board/card designs without touching the real session store.
    let isBoardDemo: Bool
    let startupWarning: String?

    init() {
        isUITesting = ProcessInfo.processInfo.environment["UI_TESTING"] == "1"
        isBoardDemo = ProcessInfo.processInfo.environment["FLOTILLA_DEMO_DATA"] == "1"
        let supportDirectory = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Flotilla", isDirectory: true)
        worktreeBaseDirectory = isUITesting
            ? Self.uiTestWorktreeBasePath
            : supportDirectory.appendingPathComponent("Worktrees", isDirectory: true)

        gitService = GitService(gitExecutable: PATHExecutableLocator().locate("git"))
        ghService = PATHExecutableLocator().locate("gh").map { GhService(ghExecutable: $0) }

        if isBoardDemo {
            // In-memory on purpose: the demo fleet must never reach the
            // user's `flotilla.sqlite`.
            let repository = Self.makeInMemoryRepositoryOrCrash()
            BoardDemoFixtures.seed(into: repository)
            sessionRepository = repository
            startupWarning = nil
        } else if isUITesting {
            let repository = (try? GRDBSessionRepository()) ?? Self.makeInMemoryRepositoryOrCrash()
            Self.seedFixtures(into: repository)
            sessionRepository = repository
            startupWarning = nil
            do {
                Self.resetUITestWorktreeDirectories()
                try Self.resetGitFixtureRepo()
                if Self.isSimulatingReviewSession {
                    try Self.resetReviewFixtureRepo()
                    Self.seedReviewFixture(into: repository)
                }
            } catch {
                preconditionFailure("UI test fixture setup failed: \(error.localizedDescription)")
            }
        } else {
            let dbPath = supportDirectory.appendingPathComponent("flotilla.sqlite")
            do {
                let repository = try GRDBSessionRepository(path: dbPath)
                sessionRepository = repository
                startupWarning = repository.recoveredFromCorruption
                    ? "The session database was damaged. Flotilla preserved a backup and started with a repaired local database."
                    : nil
            } catch {
                // The UI remains usable, but an explicit warning prevents a
                // persistence failure from masquerading as successful storage.
                sessionRepository = Self.makeInMemoryRepositoryOrCrash()
                startupWarning = "Persistent session storage is unavailable (\(error.localizedDescription)). This launch is using temporary in-memory storage."
            }
        }
    }

    private static func resetUITestWorktreeDirectories() {
        let fileManager = FileManager.default
        let fixtureWorktree = URL(fileURLWithPath: "/tmp/flotilla-fixture-project-worktrees/fix-login-bug")
        for path in [uiTestWorktreeBasePath, URL(fileURLWithPath: "/tmp/flotilla-custom-worktrees"), fixtureWorktree] {
            try? fileManager.removeItem(at: path)
            try? fileManager.createDirectory(at: path, withIntermediateDirectories: true)
        }
    }

    /// `UI_TESTING_SIMULATE_REVIEW_SESSION=1`: seed a Ready-for-Review session
    /// over a repository that already has changes to look at.
    ///
    /// Its own checkout rather than an addition to the shared fixture repo:
    /// the diff panel and file-browser tests assert against that repo's
    /// contents, and a review needs uncommitted edits, a committed change, and
    /// an untracked file, all of which would move those assertions.
    static let uiTestReviewProjectPath = URL(fileURLWithPath: "/tmp/flotilla-uitest-review")

    private static var isSimulatingReviewSession: Bool {
        ProcessInfo.processInfo.environment["UI_TESTING_SIMULATE_REVIEW_SESSION"] == "1"
    }

    /// The review fixture's session title, shared with the UI tests so a
    /// rename is a compile error there rather than a silent miss.
    static let uiTestReviewSessionTitle = "Retry the uploader"

    private static func resetReviewFixtureRepo() throws {
        let path = uiTestReviewProjectPath
        let fileManager = FileManager.default
        if fileManager.fileExists(atPath: path.path) {
            try fileManager.removeItem(at: path)
        }
        try fileManager.createDirectory(at: path, withIntermediateDirectories: true)

        let uploader = path.appendingPathComponent("Uploader.swift")
        let notes = path.appendingPathComponent("NOTES.md")

        try runGit(["init", "-b", "main"], at: path)
        try "func upload() {\n    legacyUpload()\n}\n".write(to: uploader, atomically: true, encoding: .utf8)
        try runGit(["add", "Uploader.swift"], at: path)
        try runGit(
            ["-c", "user.name=Flotilla UITests", "-c", "user.email=uitests@example.com", "commit", "-m", "init"],
            at: path
        )

        // Modified-and-uncommitted, so both review scopes have something in
        // them: the branch scope diffs the working tree against the merge
        // base, the uncommitted scope against HEAD.
        try "func upload() {\n    try await session.upload(chunk)\n}\n".write(
            to: uploader,
            atomically: true,
            encoding: .utf8
        )
        try "Untracked notes\n".write(to: notes, atomically: true, encoding: .utf8)
    }

    private static func seedReviewFixture(into repository: SessionRepository) {
        let project = Project(name: "Uploader", rootPath: uiTestReviewProjectPath)
        try? repository.save(project)
        try? repository.save(Session(
            title: uiTestReviewSessionTitle,
            goal: "Retry failed uploads on flaky networks",
            agent: .claudeCode,
            projectID: project.id,
            workingDirectory: project.rootPath,
            status: .readyForReview
        ))
    }

    private static func resetGitFixtureRepo() throws {
        let path = uiTestFixtureProjectPath
        let fileManager = FileManager.default
        if fileManager.fileExists(atPath: path.path) {
            try fileManager.removeItem(at: path)
        }
        try fileManager.createDirectory(at: path, withIntermediateDirectories: true)

        try runGit(["init", "-b", "main"], at: path)
        try "# Fixture\n".write(to: path.appendingPathComponent("README.md"), atomically: true, encoding: .utf8)
        try "# Fixture Rules\n\nBe concise.\n".write(to: path.appendingPathComponent("CLAUDE.md"), atomically: true, encoding: .utf8)
        try runGit(["add", "README.md", "CLAUDE.md"], at: path)
        try runGit(["-c", "user.name=Flotilla UITests", "-c", "user.email=uitests@example.com", "commit", "-m", "init"], at: path)
    }

    private static func runGit(_ arguments: [String], at path: URL) throws {
        let process = ChildProcessEnvironment.makeProcess()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["git"] + arguments
        process.currentDirectoryURL = path
        process.standardOutput = FileHandle.nullDevice
        let errorPipe = Pipe()
        process.standardError = errorPipe
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            let data = errorPipe.fileHandleForReading.readDataToEndOfFile()
            let stderr = String(decoding: data, as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            throw UITestFixtureError.gitFailed(arguments: arguments, status: process.terminationStatus, stderr: stderr)
        }
    }

    private enum UITestFixtureError: LocalizedError {
        case gitFailed(arguments: [String], status: Int32, stderr: String)

        var errorDescription: String? {
            switch self {
            case let .gitFailed(arguments, status, stderr):
                let detail = stderr.isEmpty ? "no error output" : stderr
                return "git \(arguments.joined(separator: " ")) exited with code \(status): \(detail)"
            }
        }
    }

    private static func makeInMemoryRepositoryOrCrash() -> GRDBSessionRepository {
        try! GRDBSessionRepository()
    }

    private static func seedFixtures(into repository: SessionRepository) {
        // Every project-scoped fixture must reference the real disposable Git
        // checkout prepared by `resetGitFixtureRepo()`. Pointing seeded
        // sessions at a placeholder directory made branch, diff, file, and
        // rule UI exercise different filesystems and hid integration bugs.
        let project = Project(name: "Flotilla", rootPath: uiTestFixtureProjectPath)
        try? repository.save(project)

        try? repository.save(Session(
            title: "Fix login bug",
            goal: "Users can't log in on Safari",
            agent: .claudeCode,
            projectID: project.id,
            workingDirectory: project.rootPath,
            worktree: WorktreeInfo(
                branchName: "flotilla/fix-login-bug",
                worktreePath: URL(fileURLWithPath: "/tmp/flotilla-fixture-project-worktrees/fix-login-bug"),
                baseCheckoutPath: project.rootPath
            ),
            status: .working
        ))
        try? repository.save(Session(
            title: "Refactor sidebar",
            goal: "Simplify the sidebar view hierarchy",
            agent: .codexCLI,
            projectID: project.id,
            workingDirectory: project.rootPath
        ))
        try? repository.save(Session(
            title: "Autonomous workflow loop",
            goal: "Implement multi-agent task delegation and verification",
            agent: .antigravity,
            projectID: project.id,
            workingDirectory: project.rootPath,
            status: .working
        ))
        try? repository.save(Session(
            title: "Build pipeline error",
            goal: "Investigate CI runner crash on macOS 15",
            agent: .claudeCode,
            projectID: project.id,
            workingDirectory: project.rootPath,
            status: .crashed
        ))
        try? repository.save(Session(
            title: "General chat",
            goal: "Ask about SwiftUI animation timing",
            agent: .openCode,
            projectID: nil,
            workingDirectory: FileManager.default.temporaryDirectory,
            status: .waitingForInput
        ))
        try? repository.save(Session(
            title: "Code review assistant",
            goal: "Analyze git diff for performance bottlenecks",
            agent: .antigravity,
            projectID: nil,
            workingDirectory: FileManager.default.temporaryDirectory,
            status: .readyForReview
        ))
    }
}

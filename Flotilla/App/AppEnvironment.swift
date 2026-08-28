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
    let startupWarning: String?

    init() {
        isUITesting = ProcessInfo.processInfo.environment["UI_TESTING"] == "1"
        let supportDirectory = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Flotilla", isDirectory: true)
        worktreeBaseDirectory = isUITesting
            ? Self.uiTestWorktreeBasePath
            : supportDirectory.appendingPathComponent("Worktrees", isDirectory: true)

        gitService = GitService(gitExecutable: PATHExecutableLocator().locate("git"))
        ghService = PATHExecutableLocator().locate("gh").map { GhService(ghExecutable: $0) }

        if isUITesting {
            let repository = (try? GRDBSessionRepository()) ?? Self.makeInMemoryRepositoryOrCrash()
            Self.seedFixtures(into: repository)
            sessionRepository = repository
            startupWarning = nil
            Self.resetUITestWorktreeDirectories()
            Self.resetGitFixtureRepo()
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

    private static func resetGitFixtureRepo() {
        let path = uiTestFixtureProjectPath
        let fileManager = FileManager.default
        try? fileManager.removeItem(at: path)
        try? fileManager.createDirectory(at: path, withIntermediateDirectories: true)

        runGit(["init", "-b", "main"], at: path)
        try? "# Fixture\n".write(to: path.appendingPathComponent("README.md"), atomically: true, encoding: .utf8)
        try? "# Fixture Rules\n\nBe concise.\n".write(to: path.appendingPathComponent("CLAUDE.md"), atomically: true, encoding: .utf8)
        runGit(["add", "README.md", "CLAUDE.md"], at: path)
        runGit(["-c", "user.name=Flotilla UITests", "-c", "user.email=uitests@example.com", "commit", "-m", "init"], at: path)
    }

    private static func runGit(_ arguments: [String], at path: URL) {
        let process = ChildProcessEnvironment.makeProcess()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["git"] + arguments
        process.currentDirectoryURL = path
        process.standardOutput = Pipe()
        process.standardError = Pipe()
        try? process.run()
        process.waitUntilExit()
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
            title: "General chat",
            goal: "Ask about SwiftUI animation timing",
            agent: .openCode,
            projectID: nil,
            workingDirectory: FileManager.default.temporaryDirectory,
            status: .waitingForInput
        ))
    }
}

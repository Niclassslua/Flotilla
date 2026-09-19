#if DEBUG
import Foundation
import SwiftUI
import SessionKit
import SettingsKit
import GitKit
import ProcessKit

/// Preview-only doubles so the four home designs can be inspected in Xcode's
/// canvas without touching the real database, git, or any subprocess. Gated to
/// DEBUG for the same reason the store's UI-testing hooks are.
///
/// These exist because `AppStore.init` calls `reload()` eagerly — a preview
/// cannot construct one without a repository that answers.
struct PreviewSessionRepository: SessionRepository {
    let projects: [Project]
    let sessions: [Session]

    func loadAll() throws -> (projects: [Project], sessions: [Session]) {
        (projects, sessions)
    }

    func save(_ project: Project) throws {}
    func save(_ session: Session) throws {}
    func delete(sessionID: UUID) throws {}
    func delete(projectID: UUID) throws {}
    func loadScrollback(sessionID: UUID) -> Data? { nil }
    func updateScrollback(sessionID: UUID, scrollback: Data) throws {}

    func loadKanbanBoards() throws -> [KanbanBoard] { [] }
    func loadKanbanBoard(id: UUID) throws -> KanbanBoard? { nil }
    func loadKanbanBoard(forProject projectID: UUID?) throws -> KanbanBoard? { nil }
    func saveKanbanBoard(_ board: KanbanBoard) throws {}
    func deleteKanbanBoard(id: UUID) throws {}

    func loadReviewComments(sessionID: UUID) throws -> [ReviewComment] { [] }
    func saveReviewComment(_ comment: ReviewComment) throws {}
    func markReviewCommentsSent(sessionID: UUID, commentIDs: Set<UUID>, at date: Date) throws {}
    func deleteReviewComment(id: UUID) throws {}
    func deleteReviewComments(sessionID: UUID) throws {}
    func loadReviewedFiles(sessionID: UUID) throws -> [ReviewedFile] { [] }
    func saveReviewedFile(_ file: ReviewedFile) throws {}
    func deleteReviewedFile(sessionID: UUID, scope: ReviewScope, filePath: String) throws {}

    func saveAttributionSession(_ snapshot: AttributionSessionSnapshot) throws {}
    func loadAttributionSessions(repositoryKey: String) throws -> [AttributionSessionSnapshot] { [] }
    func saveAttributedCommits(_ commits: [AttributedCommit], links: [AttributedCommitLink]) throws {}
    func loadAttributedCommits(repositoryKey: String) throws -> [AttributedCommit] { [] }
    func loadAttributedCommitLinks(repositoryKey: String) throws -> [AttributedCommitLink] { [] }
    func saveAttributedCommitLinks(_ links: [AttributedCommitLink]) throws {}
    func deleteAllCommitAttribution() throws {}

    func getOrCreateDefaultKanbanBoard(forProject projectID: UUID?, name: String) throws -> KanbanBoard {
        KanbanBoard(
            id: UUID(),
            projectID: projectID,
            name: name,
            columnMode: .status,
            customColumns: [],
            cardOrder: [:],
            updatedAt: Date()
        )
    }
}

struct PreviewGitService: GitServiceProtocol {
    func currentBranch(at repoPath: URL) async throws -> String { "main" }
    func status(at repoPath: URL) async throws -> GitStatus { GitStatus(entries: []) }
    func diff(at repoPath: URL, staged: Bool) async throws -> [FileDiff] { [] }
    func diffStat(at repoPath: URL) async throws -> GitDiffStat {
        GitDiffStat(additions: 128, deletions: 34)
    }
    func listWorktrees(at repoPath: URL) async throws -> [GitWorktree] { [] }
    func createWorktree(basePath: URL, branch: String, destination: URL) async throws -> GitWorktree {
        GitWorktree(branch: branch, path: destination, isMainWorktree: false)
    }
    func removeWorktree(at path: URL, in repoPath: URL, branch: String, deleteBranch: Bool) async throws {}
    func stage(paths: [String], at repoPath: URL) async throws {}
    func unstage(paths: [String], at repoPath: URL) async throws {}
    func discard(paths: [String], at repoPath: URL) async throws {}
    func commit(message: String, at repoPath: URL) async throws {}
    func push(branch: String, at repoPath: URL) async throws {}
    func fetch(at repoPath: URL) async throws {}

    func log(at repoPath: URL, ref: String?, skip: Int, maxCount: Int) async throws -> [GitCommit] {
        guard skip < Self.previewCommits.count else { return [] }
        return Array(Self.previewCommits[skip..<min(skip + maxCount, Self.previewCommits.count)])
    }

    func commitDetail(sha: String, at repoPath: URL) async throws -> GitCommitDetail {
        guard let commit = Self.previewCommits.first(where: { $0.sha == sha }) else {
            throw GitServiceError.commitNotFound(sha)
        }
        return GitCommitDetail(commit: commit, files: Self.previewFiles)
    }

    func unpushedSHAs(at repoPath: URL, ref: String?) async throws -> Set<String> {
        [Self.previewCommits[0].sha]
    }

    func remoteURL(at repoPath: URL) async throws -> String? {
        "git@github.com:Niclassslua/Flotilla.git"
    }

    /// Attributes the two newest preview commits to a session's branch, so
    /// previews exercise the agent-attribution row rather than only the
    /// plain-author fallback.
    func currentHooksPath(at repoPath: URL) async throws -> String { ".git/hooks" }

    func commitsOnBranch(_ branch: String, notOn base: String, at repoPath: URL) async throws -> Set<String> {
        Set(Self.previewCommits.prefix(2).map(\.sha))
    }

    func logGraph(at repoPath: URL, maxCount: Int) async throws -> [GitCommit] {
        Array(Self.previewCommits.prefix(maxCount))
    }

    func branches(at repoPath: URL) async throws -> [GitBranch] {
        [
            GitBranch(name: "main", isCurrent: true, isRemote: false, tipSHA: Self.previewCommits.first?.sha ?? "main"),
            GitBranch(name: "origin/main", isCurrent: false, isRemote: true, tipSHA: Self.previewCommits.first?.sha ?? "main")
        ]
    }

    func defaultBranch(at repoPath: URL) async throws -> String { "main" }

    func changesCompared(to base: String, at repoPath: URL) async throws -> [GitCommitFileChange] {
        Self.previewFiles
    }
    func uncommittedChanges(at repoPath: URL) async throws -> [GitCommitFileChange] { [] }

    func checkout(branch: String, at repoPath: URL) async throws {}
    func createAndCheckoutBranch(named branch: String, at repoPath: URL) async throws {}
    func deleteBranch(_ branch: String, force: Bool, at repoPath: URL) async throws {}
    func isBranchMerged(_ branch: String, into base: String, at repoPath: URL) async throws -> Bool { true }

    /// Spread across day boundaries so previews exercise the date grouping,
    /// and deliberately mixed — a merge, an unpushed tip, a second author.
    private static let previewCommits: [GitCommit] = [
        previewCommit(
            sha: "a1b2c3d4e5f6a7b8c9d0e1f2a3b4c5d6e7f8a9b0", short: "a1b2c3d",
            subject: "fix(git): drain the pipe without racing termination",
            body: "The readability handler and the termination handler could both\nread the same fd, truncating large diffs.",
            hoursAgo: 2, refs: [GitCommitRef(name: "HEAD", kind: .head),
                                GitCommitRef(name: "main", kind: .localBranch)],
            stat: GitDiffStat(additions: 40, deletions: 12), files: 2
        ),
        previewCommit(
            sha: "d4e5f6a7b8c9d0e1f2a3b4c5d6e7f8a9b0c1d2e3", short: "d4e5f6a",
            subject: "style(home): center the ambient glow behind the hero icon",
            hoursAgo: 5, refs: [GitCommitRef(name: "origin/main", kind: .remoteBranch)],
            stat: GitDiffStat(additions: 8, deletions: 8), files: 1
        ),
        previewCommit(
            sha: "7a8b9c0d1e2f3a4b5c6d7e8f9a0b1c2d3e4f5a6b", short: "7a8b9cd",
            subject: "Merge branch 'feat/settings'",
            hoursAgo: 26, parents: ["d4e5f6a7", "0f1e2db3"],
            stat: GitDiffStat(additions: 0, deletions: 0), files: 0
        ),
        previewCommit(
            sha: "0f1e2db3c4d5e6f7a8b9c0d1e2f3a4b5c6d7e8f9", short: "0f1e2db",
            subject: "feat(settings): move keyboard shortcuts into the settings pane",
            authorName: "Ada Lovelace", authorEmail: "ada@example.com",
            hoursAgo: 30, stat: GitDiffStat(additions: 120, deletions: 34), files: 6
        ),
        previewCommit(
            sha: "3c4d5ea6b7c8d9e0f1a2b3c4d5e6f7a8b9c0d1e2", short: "3c4d5ea",
            subject: "chore: bump dependencies",
            hoursAgo: 74, refs: [GitCommitRef(name: "v1.2.0", kind: .tag)],
            stat: GitDiffStat(additions: 11, deletions: 9), files: 3
        ),
    ]

    private static let previewFiles: [GitCommitFileChange] = [
        GitCommitFileChange(
            path: "Packages/GitKit/Sources/GitKit/CommandRunning.swift",
            kind: .modified,
            hunks: [FileDiffHunk(header: "@@ -118,7 +118,9 @@", lines: [
                " private let handle: FileHandle",
                "-    private var hasFinished = false",
                "+    private var isEOF = false",
                "+    private let eofSemaphore = DispatchSemaphore(value: 0)",
                " ",
            ])]
        ),
        GitCommitFileChange(
            path: "Flotilla/DiffPanelView.swift",
            kind: .modified,
            hunks: [FileDiffHunk(header: "@@ -48,6 +48,7 @@", lines: [
                " func monitor() async {",
                "+        await refresh()",
                " }",
            ])]
        ),
    ]

    private static func previewCommit(
        sha: String,
        short: String,
        subject: String,
        body: String = "",
        authorName: String = "Niclassslua",
        authorEmail: String = "niclassslua@users.noreply.github.com",
        hoursAgo: Double,
        parents: [String] = ["parent0000"],
        refs: [GitCommitRef] = [],
        stat: GitDiffStat,
        files: Int
    ) -> GitCommit {
        let date = Date().addingTimeInterval(-hoursAgo * 3600)
        return GitCommit(
            sha: sha, shortSHA: short, parents: parents,
            authorName: authorName, authorEmail: authorEmail, authorDate: date,
            committerName: authorName, committerEmail: authorEmail, committerDate: date,
            refs: refs, subject: subject, body: body,
            stat: stat, changedFileCount: files
        )
    }
}

enum HomePreviewData {
    static let flotilla = Project(
        id: UUID(uuidString: "11111111-1111-1111-1111-111111111111")!,
        name: "Flotilla",
        rootPath: URL(fileURLWithPath: "/Users/dev/Projects/Flotilla")
    )

    static let atlas = Project(
        id: UUID(uuidString: "22222222-2222-2222-2222-222222222222")!,
        name: "Atlas",
        rootPath: URL(fileURLWithPath: "/Users/dev/Projects/Atlas")
    )

    static let orbit = Project(
        id: UUID(uuidString: "33333333-3333-3333-3333-333333333333")!,
        name: "Orbit",
        rootPath: URL(fileURLWithPath: "/Users/dev/Projects/Orbit")
    )

    static var projects: [Project] { [flotilla, atlas, orbit] }

    static var sessions: [Session] {
        [
            session(
                "Redesign the home dashboard",
                project: flotilla,
                agent: .claudeCode,
                status: .working,
                branch: "flotilla/home-redesign",
                minutesAgo: 1
            ),
            session(
                "Fix worktree cleanup on delete",
                project: flotilla,
                agent: .claudeCode,
                status: .waitingForInput,
                branch: "flotilla/worktree-cleanup",
                minutesAgo: 4
            ),
            session(
                "Port the settings pane to Liquid Glass",
                project: atlas,
                agent: .codexCLI,
                status: .readyForReview,
                branch: "atlas/glass-settings",
                minutesAgo: 26
            ),
            session(
                "Investigate flaky terminal snapshot test",
                project: atlas,
                agent: .codexCLI,
                status: .crashed,
                branch: nil,
                minutesAgo: 95
            ),
            session(
                "Draft the migration guide",
                project: orbit,
                agent: .openCode,
                status: .readyForReview,
                branch: "orbit/migration-docs",
                minutesAgo: 240
            ),
            session(
                "Audit dependency licences",
                project: nil,
                agent: .claudeCode,
                status: nil,
                branch: nil,
                minutesAgo: 1_500
            ),
        ]
    }

    private static func session(
        _ title: String,
        project: Project?,
        agent: AgentKind,
        status: SessionStatus?,
        branch: String?,
        minutesAgo: Int
    ) -> Session {
        let root = project?.rootPath ?? URL(fileURLWithPath: "/Users/dev")
        return Session(
            id: UUID(),
            title: title,
            goal: title,
            agent: agent,
            model: nil,
            effort: nil,
            projectID: project?.id,
            workingDirectory: root,
            worktree: branch.map {
                WorktreeInfo(
                    branchName: $0,
                    worktreePath: root.appendingPathComponent(".worktrees/\($0)"),
                    baseCheckoutPath: root
                )
            },
            status: status,
            kanbanColumnID: nil,
            workflowStage: nil,
            terminalScrollback: Data(),
            createdAt: Date().addingTimeInterval(-Double(minutesAgo) * 60 - 3_600),
            lastActiveAt: Date().addingTimeInterval(-Double(minutesAgo) * 60)
        )
    }

    @MainActor
    static func makeStore() -> AppStore {
        AppStore(
            repository: PreviewSessionRepository(projects: projects, sessions: sessions),
            gitService: PreviewGitService(),
            processManager: SessionProcessManager(processFactory: MockPTYProcessFactory()),
            worktreeBaseDirectoryProvider: { URL(fileURLWithPath: NSTemporaryDirectory()) }
        )
    }
}
#endif

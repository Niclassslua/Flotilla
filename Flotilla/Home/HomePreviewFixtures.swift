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

    func loadKanbanBoards() throws -> [KanbanBoard] { [] }
    func loadKanbanBoard(id: UUID) throws -> KanbanBoard? { nil }
    func loadKanbanBoard(forProject projectID: UUID?) throws -> KanbanBoard? { nil }
    func saveKanbanBoard(_ board: KanbanBoard) throws {}
    func deleteKanbanBoard(id: UUID) throws {}

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
                status: .ready,
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
                status: .finished,
                branch: "orbit/migration-docs",
                minutesAgo: 240
            ),
            session(
                "Audit dependency licences",
                project: nil,
                agent: .claudeCode,
                status: .idle,
                branch: nil,
                minutesAgo: 1_500
            ),
        ]
    }

    private static func session(
        _ title: String,
        project: Project?,
        agent: AgentKind,
        status: SessionStatus,
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

    @MainActor
    static func makeContext() -> HomeContext {
        let store = makeStore()
        return HomeContext(
            store: store,
            settings: AppSettings(),
            activityStore: nil,
            openCodeSubscription: .none,
            defaultAgent: .claudeCode,
            openProject: { _ in },
            openSession: { _ in }
        )
    }
}
#endif

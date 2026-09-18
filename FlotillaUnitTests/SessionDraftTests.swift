import XCTest
import SessionKit
import GitKit
import PersistenceKit
import ProcessKit
import SettingsKit
@testable import Flotilla

private struct FixedExecutableLocator: ExecutableLocating {
    let executable: URL?
    let tmuxExecutable: URL?

    init(executable: URL?, tmuxExecutable: URL? = nil) {
        self.executable = executable
        self.tmuxExecutable = tmuxExecutable
    }

    func locate(_ name: String) -> URL? {
        if name == "tmux" { return tmuxExecutable }
        return executable
    }
}

/// Deterministic server-health verdicts: the real probe shells out to the
/// machine's actual tmux server, whose state must never decide a test.
private final class StubTmuxServerProbe: TmuxServerProbing, @unchecked Sendable {
    var usable: Bool
    init(usable: Bool) { self.usable = usable }
    func serverIsUsable(tmuxExecutable: URL) -> Bool { usable }
}

/// `SessionDraft` is the state both `TilesDesign` (the modal launcher)
/// and `LaunchpadDesign` (the home composer) edit. These pin the behaviour
/// that differs between the two hosts: whether an empty goal blocks
/// launching, and what a launch leaves behind in the draft afterward.
@MainActor
final class SessionDraftTests: XCTestCase {
    private func manager(factory: RecordingProcessFactory) -> SessionProcessManager {
        SessionProcessManager(
            locator: FixedExecutableLocator(executable: URL(fileURLWithPath: "/usr/bin/env")),
            processFactory: factory,
            tmuxServerProbe: StubTmuxServerProbe(usable: false)
        )
    }

    private func makeStore() throws -> AppStore {
        AppStore(
            repository: try GRDBSessionRepository(),
            gitService: MockGitService(),
            processManager: manager(factory: RecordingProcessFactory()),
            worktreeBaseDirectoryProvider: { URL(fileURLWithPath: "/tmp/worktrees") }
        )
    }

    private func makeDraft(store: AppStore, requiresGoal: Bool) -> SessionDraft {
        SessionDraft(
            store: store,
            initialProject: nil,
            initialGoal: "",
            createWorktreeByDefault: true,
            fetchBeforeCreatingWorktree: false,
            defaultAgent: .claudeCode,
            openCodeSubscription: .none,
            requiresGoal: requiresGoal
        )
    }

    func testModalDraftAllowsLaunchingWithAnEmptyGoal() throws {
        let draft = makeDraft(store: try makeStore(), requiresGoal: false)
        XCTAssertTrue(draft.canLaunch)
    }

    func testHomeDraftBlocksLaunchingWithAnEmptyGoal() throws {
        let draft = makeDraft(store: try makeStore(), requiresGoal: true)
        XCTAssertFalse(draft.canLaunch, "The always-visible home composer must require an objective")

        draft.goal = "   "
        XCTAssertFalse(draft.canLaunch, "Whitespace-only text is not an objective")

        draft.goal = "Fix the bug"
        XCTAssertTrue(draft.canLaunch)
    }

    func testClearGoalOnlyTouchesTheGoal() throws {
        let store = try makeStore()
        let draft = makeDraft(store: store, requiresGoal: true)
        draft.goal = "Fix the bug"
        draft.model = "opus"
        draft.effort = .high
        draft.createWorktree = false

        draft.clearGoal()

        XCTAssertEqual(draft.goal, "")
        XCTAssertEqual(draft.model, "opus", "Clearing the objective must not reset agent configuration")
        XCTAssertEqual(draft.effort, .high)
        XCTAssertFalse(draft.createWorktree)
    }

    func testLaunchClearsIsCreatingEvenOnFailure() async throws {
        let store = try makeStore()
        let draft = makeDraft(store: store, requiresGoal: false)
        draft.goal = "Test"
        // No project folder and the default store has no repository state to
        // fail against, so this exercises the general-session path — the
        // point here is `isCreating` resetting via `defer`, not the outcome.
        let id = await draft.launch()

        XCTAssertNotNil(id)
        XCTAssertFalse(draft.isCreating)
    }
}

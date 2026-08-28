import Foundation
import SessionKit
import HooksKit
import ProcessKit

/// Seed data for `FLOTILLA_DEMO_DATA=1`: a fleet that covers every
/// `SessionStatus`, every `SessionWaitingReason`, and every `AgentKind`, so
/// the Kanban card designs can be judged against the full range of states
/// they have to render.
///
/// Nothing here touches the real session database — the demo launch runs on
/// an in-memory repository (see `AppEnvironment`). The git checkouts are
/// real, though, and disposable: they live under `demoRoot` and are rebuilt
/// on every launch, so branch names and `+n −n` churn are genuine values
/// read by the same `DiffStatStore` polling path as production.
enum BoardDemoFixtures {
    static let demoRoot = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("flotilla-board-demo", isDirectory: true)

    struct Spec {
        let title: String
        let goal: String
        let agent: AgentKind
        let status: SessionStatus?
        let waitingReason: SessionWaitingReason?
        let branch: String?
        /// Lines added and removed in the demo checkout's working tree.
        let churn: (added: Int, removed: Int)
        /// Minutes since the session last moved, driving the elapsed readout.
        let idleMinutes: Int
        /// The agent's last visible line, served by `BoardDemoScreenReader`.
        let lastOutput: String
    }

    /// Statuses are spread across the four agents rather than repeated per
    /// agent: every state and every provider appears, without ballooning the
    /// board into forty near-identical cards.
    static let specs: [Spec] = [
        Spec(
            title: "Fix login redirect on Safari",
            goal: "Users bounce back to /login after a successful SSO round-trip.",
            agent: .claudeCode,
            status: .working,
            waitingReason: nil,
            branch: "flotilla/fix-login-redirect",
            churn: (142, 31),
            idleMinutes: 0,
            lastOutput: "● Running AuthRedirectTests… 14 passed, 1 failing"
        ),
        Spec(
            title: "Migrate settings to SwiftData",
            goal: "Replace the UserDefaults-backed settings store with SwiftData models.",
            agent: .codexCLI,
            status: .working,
            waitingReason: nil,
            branch: "flotilla/settings-swiftdata",
            churn: (388, 204),
            idleMinutes: 1,
            lastOutput: "Editing Packages/SettingsKit/Sources/SettingsKit/SettingsStore.swift:212"
        ),
        Spec(
            title: "Delete stale worktrees",
            goal: "Prune worktrees whose branches were merged more than 30 days ago.",
            agent: .claudeCode,
            status: .waitingForInput,
            waitingReason: .permission,
            branch: "flotilla/worktree-cleanup",
            churn: (24, 96),
            idleMinutes: 12,
            lastOutput: "Allow rm -rf ~/Library/…/Worktrees/merged-*? (y/n)"
        ),
        Spec(
            title: "Rework the diff viewer gutter",
            goal: "Line numbers drift out of alignment on wrapped hunks.",
            agent: .codexCLI,
            status: .waitingForInput,
            waitingReason: .question,
            branch: "flotilla/diff-gutter",
            churn: (61, 18),
            idleMinutes: 4,
            lastOutput: "Should wrapped continuation rows repeat the line number, or stay blank?"
        ),
        Spec(
            title: "Add keyboard nav to the board",
            goal: "Arrow keys move between cards; ⏎ opens the focused session.",
            agent: .openCode,
            status: .waitingForInput,
            waitingReason: .planApproval,
            branch: "flotilla/board-keynav",
            churn: (0, 0),
            idleMinutes: 27,
            lastOutput: "Plan ready — 6 steps, 4 files. Review before I start?"
        ),
        Spec(
            title: "Cache provider logos",
            goal: "Stop re-decoding the provider SVGs on every card render.",
            agent: .claudeCode,
            status: .readyForReview,
            waitingReason: nil,
            branch: "flotilla/logo-cache",
            churn: (73, 12),
            idleMinutes: 41,
            lastOutput: "Done. 3 files changed, image decode down from 4.1ms to 0.2ms."
        ),
        Spec(
            title: "Tidy the session status machine",
            goal: "Collapse the duplicated transition tables into one.",
            agent: .antigravity,
            status: .readyForReview,
            waitingReason: nil,
            branch: "flotilla/status-machine-tidy",
            churn: (48, 130),
            idleMinutes: 96,
            lastOutput: "All 355 unit tests pass. Ready for review."
        ),
        Spec(
            title: "Upgrade GRDB to 7.x",
            goal: "Pick up the new migration API and drop the vendored patch.",
            agent: .codexCLI,
            status: .crashed,
            waitingReason: nil,
            branch: "flotilla/grdb-7",
            churn: (12, 9),
            idleMinutes: 8,
            lastOutput: "error: process exited unexpectedly (SIGABRT) while resolving packages"
        ),
        Spec(
            title: "Terminal scrollback profiling",
            goal: "Find out why the ring buffer flush stalls on very wide terminals.",
            agent: .openCode,
            status: nil,
            waitingReason: nil,
            branch: nil,
            churn: (0, 0),
            idleMinutes: 3,
            lastOutput: ""
        ),
        Spec(
            title: "Document the hooks pipeline",
            goal: "Write the missing AGENTS.md section on HookCoordinator.",
            agent: .antigravity,
            status: nil,
            waitingReason: nil,
            branch: nil,
            churn: (0, 0),
            idleMinutes: 15,
            lastOutput: ""
        ),
    ]

    /// Deterministic per-index ids so `BoardDemoScreenReader` can map a
    /// session back to its spec without carrying shared mutable state.
    static func sessionID(at index: Int) -> UUID {
        UUID(uuid: (0xDE, 0xD0, 0x00, 0x00, 0x00, 0x00, 0x40, 0x00, 0xA0, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, UInt8(index)))
    }

    static let projectID = UUID(uuid: (0xDE, 0x30, 0x00, 0x00, 0x00, 0x00, 0x40, 0x00, 0xA0, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0xFF))

    static func seed(into repository: SessionRepository) {
        rebuildDemoCheckouts()

        let project = Project(id: projectID, name: "Flotilla", rootPath: demoRoot.appendingPathComponent("base"))
        try? repository.save(project)

        let now = Date()
        for (index, spec) in specs.enumerated() {
            let worktree = spec.branch.map { branch in
                WorktreeInfo(
                    branchName: branch,
                    worktreePath: checkoutPath(for: branch),
                    baseCheckoutPath: demoRoot.appendingPathComponent("base")
                )
            }
            let session = Session(
                id: sessionID(at: index),
                title: spec.title,
                goal: spec.goal,
                agent: spec.agent,
                projectID: project.id,
                workingDirectory: worktree?.worktreePath ?? demoRoot.appendingPathComponent("base"),
                worktree: worktree,
                status: spec.status,
                waitingReason: spec.waitingReason,
                createdAt: now.addingTimeInterval(-Double(spec.idleMinutes + 90) * 60),
                lastActiveAt: now.addingTimeInterval(-Double(spec.idleMinutes) * 60)
            )
            try? repository.save(session)
        }
    }

    private static func checkoutPath(for branch: String) -> URL {
        demoRoot.appendingPathComponent(branch.replacingOccurrences(of: "/", with: "-"), isDirectory: true)
    }

    /// Builds one real git repo per branch with exactly the working-tree
    /// churn the spec claims, so the diff badge shows genuine numbers rather
    /// than a mocked value that could drift from what git would report.
    private static func rebuildDemoCheckouts() {
        let fileManager = FileManager.default
        try? fileManager.removeItem(at: demoRoot)
        try? fileManager.createDirectory(at: demoRoot, withIntermediateDirectories: true)
        try? fileManager.createDirectory(at: demoRoot.appendingPathComponent("base"), withIntermediateDirectories: true)

        for spec in specs {
            guard let branch = spec.branch else { continue }
            let path = checkoutPath(for: branch)
            try? fileManager.createDirectory(at: path, withIntermediateDirectories: true)

            // Commit `removed` lines, then rewrite the file with `added`
            // different ones: git then reports exactly (added, removed).
            let committed = (0..<spec.churn.removed).map { "let committedLine\($0) = \($0)" }.joined(separator: "\n")
            let file = path.appendingPathComponent("Demo.swift")
            try? (committed + "\n").write(to: file, atomically: true, encoding: .utf8)

            git(["init", "-q", "-b", branch.replacingOccurrences(of: "/", with: "-")], at: path)
            git(["add", "-A"], at: path)
            git(["-c", "user.name=Flotilla Demo", "-c", "user.email=demo@example.com", "commit", "-q", "-m", "seed"], at: path)

            let working = (0..<spec.churn.added).map { "let workingLine\($0) = \($0)" }.joined(separator: "\n")
            try? (working + "\n").write(to: file, atomically: true, encoding: .utf8)
        }
    }

    private static func git(_ arguments: [String], at path: URL) {
        let process = ChildProcessEnvironment.makeProcess()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["git"] + arguments
        process.currentDirectoryURL = path
        process.standardOutput = Pipe()
        process.standardError = Pipe()
        try? process.run()
        process.waitUntilExit()
    }
}

/// Serves each demo session its canned last line, standing in for the PTY
/// screen reader that production uses. The board's "live output" line is one
/// of the four signals every card design has to show, so it cannot be blank
/// in a design review.
struct BoardDemoScreenReader: SessionScreenReading {
    private let screens: [UUID: String]

    init() {
        var screens: [UUID: String] = [:]
        for (index, spec) in BoardDemoFixtures.specs.enumerated() where !spec.lastOutput.isEmpty {
            screens[BoardDemoFixtures.sessionID(at: index)] = spec.lastOutput
        }
        self.screens = screens
    }

    func readScreen(for sessionID: UUID) async -> String? {
        screens[sessionID]
    }
}

import Foundation
import SessionKit
import HooksKit
import ProcessKit
import PersistenceKit

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
        Spec(
            title: "Wire Cursor Agent launch path",
            goal: "Land the agent binary, model catalog, and session resume for Cursor.",
            agent: .cursorAgent,
            status: .working,
            waitingReason: nil,
            branch: "flotilla/cursor-agent",
            churn: (56, 8),
            idleMinutes: 2,
            lastOutput: "● Fetching model list from `agent models`…"
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

    /// Builds a real git repository in base with rich commit history across
    /// the last 53 weeks and linked worktrees for each branch, so Home widgets,
    /// git graphs, and diff badges display genuine statistics.
    private static func rebuildDemoCheckouts() {
        let fileManager = FileManager.default
        try? fileManager.removeItem(at: demoRoot)
        try? fileManager.createDirectory(at: demoRoot, withIntermediateDirectories: true)
        let basePath = demoRoot.appendingPathComponent("base")
        try? fileManager.createDirectory(at: basePath, withIntermediateDirectories: true)

        seedBaseRepository(at: basePath)

        for spec in specs {
            guard let branch = spec.branch else { continue }
            let path = checkoutPath(for: branch)
            let branchName = branch.replacingOccurrences(of: "/", with: "-")

            // Create a real linked worktree from base so git worktree list,
            // default branch detection, and diff calculations work seamlessly.
            git(["worktree", "add", "-q", path.path, "-b", branchName], at: basePath)

            // Commit `removed` lines, then rewrite the file with `added`
            // different ones: git then reports exactly (added, removed).
            let committed = (0..<spec.churn.removed).map { "let committedLine\($0) = \($0)" }.joined(separator: "\n")
            let file = path.appendingPathComponent("Demo.swift")
            try? (committed + "\n").write(to: file, atomically: true, encoding: .utf8)

            git(["add", "-A"], at: path)
            git(["-c", "user.name=Flotilla Demo", "-c", "user.email=demo@example.com", "commit", "-q", "-m", "seed"], at: path)

            let working = (0..<spec.churn.added).map { "let workingLine\($0) = \($0)" }.joined(separator: "\n")
            try? (working + "\n").write(to: file, atomically: true, encoding: .utf8)
        }
    }

    private static func seedBaseRepository(at path: URL) {
        let fileManager = FileManager.default
        let sourcesPath = path.appendingPathComponent("Sources/Flotilla", isDirectory: true)
        try? fileManager.createDirectory(at: sourcesPath, withIntermediateDirectories: true)

        git(["init", "-q", "-b", "main"], at: path)
        git(["config", "user.name", "Flotilla Demo"], at: path)
        git(["config", "user.email", "demo@example.com"], at: path)

        let initialFiles: [String: String] = [
            "README.md": "# Flotilla\n\nLocal command center for coding agents.\n",
            "Package.swift": "// swift-tools-version: 6.0\nimport PackageDescription\n\nlet package = Package(name: \"Flotilla\")\n",
            "Sources/Flotilla/App.swift": "import SwiftUI\n\n@main\nstruct FlotillaApp {\n    var body: some Scene {\n        WindowGroup { Text(\"Flotilla\") }\n    }\n}\n",
            "Sources/Flotilla/Store.swift": "import Foundation\n\nfinal class AppStore {\n    var sessions: [String] = []\n}\n",
            "Sources/Flotilla/Terminal.swift": "import AppKit\n\nfinal class TerminalManager {\n    func reset() {}\n}\n",
            "Sources/Flotilla/GitService.swift": "import Foundation\n\nfinal class GitService {\n    func status() {}\n}\n",
            "Sources/Flotilla/Dashboard.swift": "import SwiftUI\n\nstruct HomeDashboardView: View {\n    var body: some View { Text(\"Home\") }\n}\n",
            "Sources/Flotilla/Settings.swift": "import Foundation\n\nfinal class SettingsViewModel {\n    var autoStart = true\n}\n",
        ]
        for (rel, content) in initialFiles {
            let fileURL = path.appendingPathComponent(rel)
            try? content.write(to: fileURL, atomically: true, encoding: .utf8)
        }
        git(["add", "-A"], at: path)

        let calendar = Calendar.current
        let now = Date()
        let isoFormatter = ISO8601DateFormatter()
        isoFormatter.formatOptions = [.withInternetDateTime]

        let initDate = calendar.date(byAdding: .weekOfYear, value: -36, to: now) ?? now
        git([
            "-c", "user.name=Niclassslua",
            "-c", "user.email=niclassslua@users.noreply.github.com",
            "commit", "-q",
            "--date", isoFormatter.string(from: initDate),
            "-m", "Initial commit",
        ], at: path)

        struct CommitSeed {
            let daysAgo: Double
            let hour: Int
            let author: String
            let email: String
            let agent: AgentKind?
            let message: String
            let file: String
            let lines: Int
        }

        var seeds: [CommitSeed] = []

        // Weekly commits going back 32 weeks for codebase growth and heatmap
        let olderWeeks = [32, 28, 24, 21, 18, 15, 13, 11, 9, 7, 5]
        for (idx, week) in olderWeeks.enumerated() {
            let lines = 35 + idx * 8
            seeds.append(CommitSeed(
                daysAgo: Double(week * 7 + (week % 4)),
                hour: 10 + (idx % 8),
                author: "Niclassslua",
                email: "niclassslua@users.noreply.github.com",
                agent: nil,
                message: "feat: sprint \(week) architecture and models",
                file: "Sources/Flotilla/Store.swift",
                lines: lines
            ))
        }

        // Recent commits across the last 28 days for rhythm, streak, today, and agent share
        let recentCommits: [(daysAgo: Double, hour: Int, author: String, email: String, agent: AgentKind?, msg: String, file: String, lines: Int)] = [
            (26, 14, "Claude Code", "claude@anthropic.com", .claudeCode, "refactor(agent): stream tool call progress", "Sources/Flotilla/App.swift", 35),
            (23, 11, "Codex", "codex@openai.com", .codexCLI, "fix(terminal): drain scrollback on exit", "Sources/Flotilla/Terminal.swift", 40),
            (20, 16, "Niclassslua", "niclassslua@users.noreply.github.com", nil, "feat(dashboard): add project card loose ends", "Sources/Flotilla/Dashboard.swift", 60),
            (17, 10, "OpenCode", "opencode@opencode.ai", .openCode, "feat(plan): parse plan mode step lists", "Sources/Flotilla/Store.swift", 50),
            (14, 15, "Antigravity", "antigravity@google.com", .antigravity, "perf(git): cache merge-base computations", "Sources/Flotilla/GitService.swift", 45),
            (12, 11, "Claude Code", "claude@anthropic.com", .claudeCode, "feat(hooks): forward pre-tool notifications", "Sources/Flotilla/App.swift", 70),
            (10, 14, "Codex", "codex@openai.com", .codexCLI, "fix(settings): persist default editor font size", "Sources/Flotilla/Settings.swift", 25),
            (8, 16, "Niclassslua", "niclassslua@users.noreply.github.com", nil, "feat(ui): refine glass cards and glow", "Sources/Flotilla/Dashboard.swift", 80),
            (7, 10, "Antigravity", "antigravity@google.com", .antigravity, "refactor(status): simplify session transitions", "Sources/Flotilla/Store.swift", 30),
            (5, 11, "OpenCode", "opencode@opencode.ai", .openCode, "chore(deps): update local package dependencies", "Package.swift", 20),
            (4, 14, "Claude Code", "claude@anthropic.com", .claudeCode, "feat(diff): add gutter line wrapping", "Sources/Flotilla/Dashboard.swift", 65),
            (3, 9, "Codex", "codex@openai.com", .codexCLI, "fix(sessions): handle unexpected SIGABRT", "Sources/Flotilla/Store.swift", 35),
            (2, 15, "Claude Code", "claude@anthropic.com", .claudeCode, "feat(home): add busiest hours matrix", "Sources/Flotilla/Dashboard.swift", 90),
            (2, 20, "OpenCode", "opencode@opencode.ai", .openCode, "test(terminal): add snapshot tests for resize", "Sources/Flotilla/Terminal.swift", 45),
            (1, 10, "Antigravity", "antigravity@google.com", .antigravity, "feat(git): add worktree list helper", "Sources/Flotilla/GitService.swift", 75),
            (1, 14, "Cursor Agent", "cursor@cursor.com", .cursorAgent, "feat(agent): add Cursor Agent launch path", "Sources/AgentKit/CursorSessionProvider.swift", 40),
            (1, 16, "Niclassslua", "niclassslua@users.noreply.github.com", nil, "docs: update hook coordinator architecture", "README.md", 25),
            (0, 9, "Niclassslua", "niclassslua@users.noreply.github.com", nil, "feat(shell): polish navigation bar layout", "Sources/Flotilla/Dashboard.swift", 45),
            (0, 11, "Claude Code", "claude@anthropic.com", .claudeCode, "fix(home): adjust chart layout and spacing", "Sources/Flotilla/Dashboard.swift", 30),
            (0, 15, "Codex", "codex@openai.com", .codexCLI, "refactor(terminal): optimize ring buffer read", "Sources/Flotilla/Terminal.swift", 55),
        ]
        for r in recentCommits {
            seeds.append(CommitSeed(
                daysAgo: r.daysAgo,
                hour: r.hour,
                author: r.author,
                email: r.email,
                agent: r.agent,
                message: r.msg,
                file: r.file,
                lines: r.lines
            ))
        }

        // Sort chronologically (oldest first)
        seeds.sort { $0.daysAgo > $1.daysAgo }

        for (idx, seed) in seeds.enumerated() {
            var date = calendar.date(byAdding: .day, value: -Int(seed.daysAgo), to: now) ?? now
            date = calendar.date(bySettingHour: seed.hour, minute: 15 + (idx % 30), second: 0, of: date) ?? date

            let targetFile = path.appendingPathComponent(seed.file)
            let snippet = "\n// Commit \(idx): \(seed.message)\n" + (0..<seed.lines).map { "let line_\(idx)_\($0) = \($0)" }.joined(separator: "\n") + "\n"
            if let handle = try? FileHandle(forWritingTo: targetFile) {
                _ = handle.seekToEndOfFile()
                handle.write(Data(snippet.utf8))
                try? handle.close()
            }

            let trailer = seed.agent.map { "\n\nFlotilla-Agent: \($0.rawValue)" } ?? ""
            git([
                "-c", "user.name=\(seed.author)",
                "-c", "user.email=\(seed.email)",
                "commit", "-q", "-a",
                "--date", isoFormatter.string(from: date),
                "-m", "\(seed.message)\(trailer)",
            ], at: path)
        }

        // Leave uncommitted changes in base so Loose Ends widget and project card
        // reflect real, active workspace status.
        let readme = path.appendingPathComponent("README.md")
        if let handle = try? FileHandle(forWritingTo: readme) {
            _ = handle.seekToEndOfFile()
            handle.write(Data("\n## Active Workspace Notes\n- Review diff gutter line numbering\n".utf8))
            try? handle.close()
        }
        let notes = path.appendingPathComponent("NOTES.md")
        try? "# Uncommitted Notes\n- Check sprint deliverables\n".write(to: notes, atomically: true, encoding: .utf8)
    }

    /// Seeds realistic permission requests for the demo fleet, so Home's Top Permissions
    /// widget displays genuine pattern statistics across agents.
    static func seedPermissions(into store: PermissionLogStore) {
        let now = Date()
        let asks: [(pattern: String, tool: String, agent: String, minutesAgo: Int)] = [
            ("Bash(git push *)", "Bash", "claudeCode", 15),
            ("Bash(git push *)", "Bash", "claudeCode", 55),
            ("Bash(git push *)", "Bash", "claudeCode", 140),
            ("Bash(swift test)", "Bash", "codexCLI", 25),
            ("Bash(swift test)", "Bash", "codexCLI", 80),
            ("Bash(swift test)", "Bash", "codexCLI", 210),
            ("Bash(swift test)", "Bash", "antigravity", 40),
            ("FileEdit(Sources/*)", "FileEdit", "claudeCode", 30),
            ("FileEdit(Sources/*)", "FileEdit", "codexCLI", 70),
            ("FileEdit(Packages/*)", "FileEdit", "antigravity", 90),
            ("FileEdit(Packages/*)", "FileEdit", "openCode", 120),
            ("FileRead(.env)", "FileRead", "codexCLI", 105),
            ("Bash(npm test)", "Bash", "openCode", 160),
            ("Bash(cargo check)", "Bash", "antigravity", 180),
        ]
        for (index, ask) in asks.enumerated() {
            let sessionID = sessionID(at: index % specs.count).uuidString
            try? store.record(
                sessionID: sessionID,
                agent: ask.agent,
                tool: ask.tool,
                pattern: ask.pattern,
                at: now.addingTimeInterval(-Double(ask.minutesAgo) * 60)
            )
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

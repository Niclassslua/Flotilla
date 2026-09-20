import Foundation
import SessionKit

/// The fleet the navigator design sweep is judged against: four projects with
/// four different icon kinds and accent colours, sessions spread across every
/// status, and two unassigned ones for the General section.
///
/// The UI-test fixtures would not do — they have a single, icon-less project,
/// and the whole question here is how a project's identity reads in a column
/// this narrow. `BoardDemoFixtures` would not either: it seeds real git
/// checkouts, and `AppStore.restoreSessions()` then launches real agents
/// against them.
enum SidebarShotFixtures {
    static func seed(into repository: SessionRepository) {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("flotilla-sidebar-shot", isDirectory: true)

        let specs: [(name: String, icon: ProjectIcon?, accent: String?, sessions: [SessionSpec])] = [
            (
                "Flotilla", .symbol(name: "sailboat.fill"), "#E8833A",
                [
                    SessionSpec("Fix login redirect", .claudeCode, .working, nil, "flotilla/fix-login-redirect", 0),
                    SessionSpec("Rework the navigator", .codexCLI, .waitingForInput, .permission, "flotilla/navigator", 3),
                    SessionSpec("Migrate settings to SwiftData", .codexCLI, .readyForReview, nil, "flotilla/settings-swiftdata", 41),
                    SessionSpec("Prune stale worktrees", .claudeCode, nil, nil, nil, 1_500)
                ]
            ),
            (
                "Harbour API", .emoji("🛰"), "#5AA9E6",
                [
                    SessionSpec("Rate-limit the webhook", .openCode, .working, nil, "harbour/webhook-limits", 2),
                    SessionSpec("Answer the schema question", .claudeCode, .waitingForInput, .question, "harbour/schema", 17)
                ]
            ),
            (
                "Companion", .symbol(name: "iphone.gen3"), "#9B7BD4",
                [
                    SessionSpec("Pairing handshake retry", .antigravity, .crashed, nil, "companion/pairing-retry", 96),
                    SessionSpec("Transcript layout pass", .claudeCode, .readyForReview, nil, "companion/transcript", 6)
                ]
            ),
            (
                "Dockyard", nil, nil,
                [SessionSpec("Nightly build triage", .codexCLI, .working, nil, "dockyard/nightly", 8)]
            )
        ]

        for spec in specs {
            let project = Project(
                name: spec.name,
                rootPath: root.appendingPathComponent(spec.name.lowercased()),
                icon: spec.icon,
                accentColor: spec.accent
            )
            try? repository.save(project)
            for session in spec.sessions {
                try? repository.save(session.make(projectID: project.id, root: project.rootPath))
            }
        }

        for session in [
            SessionSpec("General chat", .openCode, .waitingForInput, .planApproval, nil, 4),
            SessionSpec("Code review assistant", .antigravity, .readyForReview, nil, nil, 120)
        ] {
            try? repository.save(session.make(projectID: nil, root: root))
        }
    }

    struct SessionSpec {
        let title: String
        let agent: AgentKind
        let status: SessionStatus?
        let waitingReason: SessionWaitingReason?
        let branch: String?
        /// Minutes since the session last moved, so the rows show a spread of
        /// ages rather than a column of "now".
        let idleMinutes: Int

        init(
            _ title: String,
            _ agent: AgentKind,
            _ status: SessionStatus?,
            _ waitingReason: SessionWaitingReason?,
            _ branch: String?,
            _ idleMinutes: Int
        ) {
            self.title = title
            self.agent = agent
            self.status = status
            self.waitingReason = waitingReason
            self.branch = branch
            self.idleMinutes = idleMinutes
        }

        func make(projectID: UUID?, root: URL) -> Session {
            Session(
                title: title,
                goal: title,
                agent: agent,
                projectID: projectID,
                workingDirectory: root,
                worktree: branch.map {
                    WorktreeInfo(
                        branchName: $0,
                        worktreePath: root.appendingPathComponent($0.split(separator: "/").last.map(String.init) ?? "wt"),
                        baseCheckoutPath: root
                    )
                },
                status: status,
                waitingReason: waitingReason,
                lastActiveAt: Date().addingTimeInterval(-Double(idleMinutes) * 60)
            )
        }
    }
}

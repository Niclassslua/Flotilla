import Foundation
import SessionKit
import CompanionKit

/// The prototype's fixture fleet: a reachable Mac with sessions spanning every
/// status and waiting reason, and an unreachable one with cached sessions.
struct MockFixtures {
    var macs: [MacHost]
    var sessionsByMac: [MacHost.ID: [CompanionSession]]
    var projectsByMac: [MacHost.ID: [ProjectSummary]]
    var transcripts: [CompanionSession.ID: SessionTranscript] = [:]
    var pending: [CompanionSession.ID: [PendingInteraction]] = [:]
    var diffs: [CompanionSession.ID: [FileDiff]] = [:]
    var commits: [CompanionSession.ID: [CommitSummary]] = [:]
    var files: [String: String] = [:]
    var gatedToolCalls: [PendingInteraction.ID: (useID: String, output: String)] = [:]

    enum MacID {
        static let studio = "studio"
        static let macBook = "macbook"
    }

    enum ProjectID {
        static let flotilla = UUID(uuidString: "0F107111-0000-4000-A000-000000000001")!
        static let harbor = UUID(uuidString: "0F107111-0000-4000-A000-000000000002")!
    }

    enum SessionID {
        static let offlineBanner = UUID(uuidString: "0F107111-0000-4000-B000-000000000001")!
        static let flakyTest = UUID(uuidString: "0F107111-0000-4000-B000-000000000002")!
        static let authQuestion = UUID(uuidString: "0F107111-0000-4000-B000-000000000003")!
        static let settingsPlan = UUID(uuidString: "0F107111-0000-4000-B000-000000000004")!
        static let readmeReview = UUID(uuidString: "0F107111-0000-4000-B000-000000000005")!
        static let dependencyCrash = UUID(uuidString: "0F107111-0000-4000-B000-000000000006")!
        static let weeklyQuota = UUID(uuidString: "0F107111-0000-4000-B000-000000000007")!
        static let releaseNotes = UUID(uuidString: "0F107111-0000-4000-B000-000000000008")!
        static let launchProfile = UUID(uuidString: "0F107111-0000-4000-B000-000000000009")!
    }

    static func standard(now: Date = .now) -> MockFixtures {
        func ago(_ minutes: Double) -> Date { now.addingTimeInterval(-minutes * 60) }
        let lastSeen = Calendar.current.date(bySettingHour: 14, minute: 2, second: 0, of: now) ?? ago(90)

        var fixtures = MockFixtures(
            macs: [
                MacHost(id: MacID.studio, name: "Studio", connection: .connected(path: .lan, address: "192.168.1.20"), lastSeen: now),
                MacHost(id: MacID.macBook, name: "MacBook Pro", connection: .unreachable, lastSeen: min(lastSeen, ago(5))),
            ],
            sessionsByMac: [:],
            projectsByMac: [
                MacID.studio: [
                    ProjectSummary(id: ProjectID.flotilla, name: "Flotilla"),
                    ProjectSummary(id: ProjectID.harbor, name: "Harbor API"),
                ],
                MacID.macBook: [ProjectSummary(id: ProjectID.flotilla, name: "Flotilla")],
            ]
        )
        fixtures.files = sampleFiles

        // MARK: Studio

        let bannerDiff = sampleDiff
        fixtures.sessionsByMac[MacID.studio] = [
            CompanionSession(
                id: SessionID.offlineBanner, title: "Add unreachable banner to fleet", agent: .claudeCode,
                model: "opus", effort: .high, status: .working, projectID: ProjectID.flotilla,
                branch: "flotilla/unreachable-banner", hasWorktree: true, isProcessLive: true,
                updatedAt: ago(1), diffStat: bannerDiff.stat
            ),
            CompanionSession(
                id: SessionID.flakyTest, title: "Fix flaky snapshot test", agent: .codexCLI,
                model: "gpt-5.6-sol", effort: .medium, status: .waitingForInput, waitingReason: .permission,
                projectID: ProjectID.flotilla, branch: "flotilla/flaky-snapshot", hasWorktree: true,
                isProcessLive: true, updatedAt: ago(3), attentionSummary: "Allow rm -rf build?"
            ),
            CompanionSession(
                id: SessionID.authQuestion, title: "Add token refresh to client", agent: .openCode,
                model: "opencode-go/glm-5.3", status: .waitingForInput, waitingReason: .question,
                projectID: ProjectID.harbor, branch: "harbor/token-refresh", hasWorktree: true,
                isProcessLive: true, updatedAt: ago(6), attentionSummary: "Where should refresh tokens live?"
            ),
            CompanionSession(
                id: SessionID.settingsPlan, title: "Migrate settings storage", agent: .claudeCode,
                model: "sonnet", effort: .medium, status: .waitingForInput, waitingReason: .planApproval,
                projectID: ProjectID.harbor, branch: nil, hasWorktree: false, isProcessLive: true,
                updatedAt: ago(9), attentionSummary: "Move settings to SQLite"
            ),
            CompanionSession(
                id: SessionID.readmeReview, title: "Refresh README screenshots", agent: .antigravity,
                model: "gemini-3.7-flash-high", effort: .medium, status: .readyForReview,
                projectID: ProjectID.flotilla, branch: "flotilla/readme-shots", hasWorktree: true,
                isProcessLive: false, updatedAt: ago(22), diffStat: bannerDiff.stat
            ),
            CompanionSession(
                id: SessionID.dependencyCrash, title: "Bump package dependencies", agent: .codexCLI,
                model: "gpt-5.5", effort: .low, status: .crashed, projectID: nil, branch: nil,
                hasWorktree: false, isProcessLive: false, updatedAt: ago(35),
                crashReason: "Process exited with code 137 (killed)"
            ),
            CompanionSession(
                id: SessionID.weeklyQuota, title: "Summarise this week's issues", agent: .claudeCode,
                model: "opus", effort: .max, status: .readyForReview, projectID: nil, branch: nil,
                hasWorktree: false, isProcessLive: true, updatedAt: ago(48), failure: "quota exceeded",
                reviewAcknowledged: true
            ),
        ]

        fixtures.transcripts[SessionID.offlineBanner] = TranscriptBuilder(start: ago(12)) { t in
            t.user("When a Mac drops off, show a sticky banner on its fleet and disable every action.")
            t.assistant("I'll add an `UnreachableBanner` and gate the fleet's actions on reachability.")
            t.tool("Grep", ["pattern": "isReachable"], output: "3 matches")
            t.tool("Read", ["file_path": "FlotillaCompanion/Features/Fleet/FleetView.swift"], output: "184 lines")
            t.tool("Write", ["file_path": "FlotillaCompanion/Components/UnreachableBanner.swift"], output: "Created")
            t.tool("Edit", ["file_path": "FlotillaCompanion/Features/Fleet/FleetView.swift"], output: "Applied")
            t.assistant("The banner is in. Now wiring the disabled state into swipe actions and the **+** button.")
            t.tool("Bash", ["command": "xcodebuild -scheme FlotillaCompanion build"], output: nil)
        }.transcript
        fixtures.diffs[SessionID.offlineBanner] = bannerDiff
        fixtures.commits[SessionID.offlineBanner] = sampleCommits(now: now)

        let flakyUseID = "fixture-rm-build"
        fixtures.transcripts[SessionID.flakyTest] = TranscriptBuilder(start: ago(10)) { t in
            t.user("The terminal snapshot test fails about one run in five. Find out why and fix it.")
            t.tool("shell", ["command": "swift test --filter TerminalSnapshotTests"], output: "1 failure: frame mismatch at row 12", isError: true)
            t.assistant("The failure comes from a stale build cache holding an old font atlas. I want to clear it and rerun.")
            t.tool("shell", ["command": "rm -rf build"], output: nil, id: flakyUseID)
        }.transcript
        let flakyPermission = PendingInteraction(
            kind: .permission(PermissionRequest(tool: "Bash", summary: "rm -rf build", detail: "rm -rf build", pattern: "rm *")),
            raisedAt: ago(3)
        )
        fixtures.pending[SessionID.flakyTest] = [flakyPermission]
        fixtures.gatedToolCalls[flakyPermission.id] = (flakyUseID, "Removed build/")
        fixtures.diffs[SessionID.flakyTest] = []

        fixtures.transcripts[SessionID.authQuestion] = TranscriptBuilder(start: ago(14)) { t in
            t.user("Add token refresh to the API client.")
            t.tool("read", ["file_path": "Sources/Client/APIClient.swift"], output: "312 lines")
            t.assistant("Before I start I need two decisions from you.")
        }.transcript
        fixtures.pending[SessionID.authQuestion] = [PendingInteraction(kind: .question(sampleQuestions), raisedAt: ago(6))]

        fixtures.transcripts[SessionID.settingsPlan] = TranscriptBuilder(start: ago(20)) { t in
            t.user("Settings are a JSON blob in UserDefaults. Move them somewhere we can migrate.")
            t.tool("Read", ["file_path": "Sources/Settings/SettingsStore.swift"], output: "140 lines")
            t.tool("Grep", ["pattern": "UserDefaults.standard"], output: "11 matches")
            t.assistant("I've mapped every read and write. Here's the plan.")
        }.transcript
        fixtures.pending[SessionID.settingsPlan] = [PendingInteraction(kind: .plan(samplePlan), raisedAt: ago(9))]

        fixtures.transcripts[SessionID.readmeReview] = TranscriptBuilder(start: ago(40)) { t in
            t.user("Retake the README screenshots in dark mode.")
            t.tool("run_command", ["command": "make screenshots"], output: "7 screenshots written")
            t.tool("Edit", ["file_path": "README.md"], output: "Applied")
            t.assistant("Screenshots are refreshed and the README points at the new files.")
        }.transcript
        fixtures.diffs[SessionID.readmeReview] = bannerDiff
        fixtures.commits[SessionID.readmeReview] = sampleCommits(now: now)

        fixtures.transcripts[SessionID.dependencyCrash] = TranscriptBuilder(start: ago(50)) { t in
            t.user("Bump all package dependencies to their latest minor versions.")
            t.tool("shell", ["command": "swift package update"], output: nil)
        }.transcript

        fixtures.transcripts[SessionID.weeklyQuota] = TranscriptBuilder(start: ago(60)) { t in
            t.user("Summarise this week's closed issues by area.")
            t.tool("Bash", ["command": "gh issue list --state closed --limit 200"], output: "143 issues")
            t.failure("Turn failed · quota exceeded")
        }.transcript

        // MARK: MacBook (unreachable, cached)

        fixtures.sessionsByMac[MacID.macBook] = [
            CompanionSession(
                id: SessionID.launchProfile, title: "Profile launch time", agent: .codexCLI,
                model: "gpt-5.6-terra", effort: .high, status: .working, projectID: ProjectID.flotilla,
                branch: "flotilla/launch-profile", hasWorktree: true, isProcessLive: true, updatedAt: ago(95)
            ),
            CompanionSession(
                id: SessionID.releaseNotes, title: "Draft release notes", agent: .claudeCode,
                model: "sonnet", effort: .medium, status: .readyForReview, projectID: ProjectID.flotilla,
                branch: nil, hasWorktree: false, isProcessLive: false, updatedAt: ago(120),
                diffStat: DiffStat(files: 1, additions: 42, deletions: 3)
            ),
        ]
        fixtures.transcripts[SessionID.launchProfile] = TranscriptBuilder(start: ago(110)) { t in
            t.user("Launch takes 1.8 s. Find where the time goes.")
            t.tool("shell", ["command": "xcrun xctrace record --template 'App Launch'"], output: "Trace saved")
            t.assistant("Most of it is the GRDB migrator running on the main thread. Moving it off next.")
        }.transcript
        fixtures.transcripts[SessionID.releaseNotes] = TranscriptBuilder(start: ago(130)) { t in
            t.user("Draft release notes for 0.2 from the changelog.")
            t.tool("Read", ["file_path": "CHANGELOG.md"], output: "220 lines")
            t.assistant("Draft is in `RELEASE_NOTES.md` — grouped into Sessions, Git, and Fixes.")
        }.transcript

        return fixtures
    }
}

// MARK: - Builders

struct TranscriptBuilder {
    private(set) var transcript = SessionTranscript()
    private var clock: Date

    init(start: Date, _ build: (inout TranscriptBuilder) -> Void) {
        clock = start
        build(&self)
    }

    private mutating func tick() -> Date {
        clock = clock.addingTimeInterval(20)
        return clock
    }

    mutating func user(_ text: String) {
        transcript.append(.userMessage(text: text, timestamp: tick()))
    }

    mutating func assistant(_ text: String) {
        transcript.append(.assistantMessage(text: text, timestamp: tick()))
    }

    /// A tool call; `output: nil` leaves it running.
    mutating func tool(_ tool: String, _ input: [String: String], output: String?, isError: Bool = false, id: String = UUID().uuidString) {
        transcript.append(.toolUse(id: id, tool: tool, input: input, timestamp: tick()))
        if let output {
            transcript.append(.toolResult(toolUseID: id, output: output, isError: isError, timestamp: tick()))
        }
    }

    mutating func failure(_ message: String) {
        _ = tick()
        transcript.append(.turnFailed(message: message))
    }
}

extension MockFixtures {
    // MARK: - Canned content

    static let sampleReply = """
    Done. Here's what changed:
    - The fleet shows a sticky banner while the Mac is unreachable.
    - Swipe actions, **+**, and the composer are disabled offline.
    - Cached transcripts stay readable.
    The build passes; nothing else was touched.
    """

    static let terminalTailFrames = [
        "▸ Planning next step…",
        "▸ Planning next step…\n  reading FleetView.swift",
        "  reading FleetView.swift\n  editing UnreachableBanner.swift\n  ✓ 1 file changed",
        "  ✓ 1 file changed\n  running xcodebuild…\n  ** BUILD SUCCEEDED **",
    ]

    static let sampleQuestions = [
        QuestionStep(
            id: "storage",
            header: "Storage",
            prompt: "Where should refresh tokens live?",
            options: [
                .init(label: "Keychain", description: "Survives reinstall on the same device"),
                .init(label: "In memory", description: "Log in again after every launch"),
            ],
            allowsMultiple: false
        ),
        QuestionStep(
            id: "triggers",
            header: "Triggers",
            prompt: "When should the client refresh?",
            options: [
                .init(label: "On 401 responses", description: nil),
                .init(label: "Before expiry", description: "Five minutes ahead"),
                .init(label: "On app foreground", description: nil),
            ],
            allowsMultiple: true
        ),
    ]

    static let samplePlan = PlanProposal(
        title: "Move settings to SQLite",
        markdown: """
        ## Move settings to SQLite

        Settings live in one JSON blob under `UserDefaults`, so nothing can be migrated field by field.

        ### Steps

        1. Add a `settings` table to the existing GRDB database with one row per key.
        2. Write a one-time migrator that reads the blob and inserts each key.
        3. Replace `SettingsStore`'s reads and writes (11 call sites).
        4. Keep the blob for one release as a fallback, then delete it.

        ### Risks

        - A crash mid-migration must leave the blob intact — the migrator runs in a transaction and only then clears it.
        - `SettingsView` observes the store; the table needs a change notification to keep that working.
        """
    )

    static let sampleDiff: [FileDiff] = [
        FileDiff(
            path: "FlotillaCompanion/Components/UnreachableBanner.swift",
            change: .added,
            hunks: [DiffHunk(header: "@@ -0,0 +1,14 @@", unified: """
            +import SwiftUI
            +
            +struct UnreachableBanner: View {
            +    let mac: MacHost
            +
            +    var body: some View {
            +        Label("\\(mac.name) is unreachable · last seen \\(mac.lastSeen.formatted(date: .omitted, time: .shortened))", systemImage: "wifi.slash")
            +            .font(.footnote.weight(.medium))
            +            .frame(maxWidth: .infinity)
            +            .padding(.vertical, 8)
            +            .background(.orange.opacity(0.15))
            +    }
            +}
            +
            """)]
        ),
        FileDiff(
            path: "FlotillaCompanion/Features/Fleet/FleetView.swift",
            change: .modified,
            hunks: [
                DiffHunk(header: "@@ -41,7 +41,9 @@ struct FleetView: View {", unified: """
                         List {
                             needsYouSection
                             projectSections
                         }
                -        .toolbar { toolbarContent }
                +        .safeAreaInset(edge: .top) {
                +            if !mac.isReachable { UnreachableBanner(mac: mac) }
                +        }
                +        .toolbar { toolbarContent }
                """),
                DiffHunk(header: "@@ -88,6 +90,7 @@ struct FleetView: View {", unified: """
                         Button("New Session", systemImage: "plus") { isCreating = true }
                +            .disabled(!mac.isReachable)
                     }
                """),
            ]
        ),
        FileDiff(
            path: "README.md",
            change: .modified,
            hunks: [DiffHunk(header: "@@ -12,4 +12,4 @@", unified: """
             ## Screenshots

            -![Fleet](docs/images/fleet-light.png)
            +![Fleet](docs/images/fleet-dark.png)
            """)]
        ),
    ]

    static let sampleFiles: [String: String] = [
        "FlotillaCompanion/Components/UnreachableBanner.swift": """
        import SwiftUI

        struct UnreachableBanner: View {
            let mac: MacHost

            var body: some View {
                Label("\\(mac.name) is unreachable", systemImage: "wifi.slash")
                    .font(.footnote.weight(.medium))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
                    .background(.orange.opacity(0.15))
            }
        }
        """,
        "FlotillaCompanion/Features/Fleet/FleetView.swift": """
        import SwiftUI

        struct FleetView: View {
            let mac: MacHost
            @State private var isCreating = false

            var body: some View {
                List {
                    needsYouSection
                    projectSections
                }
                .safeAreaInset(edge: .top) {
                    if !mac.isReachable { UnreachableBanner(mac: mac) }
                }
                .toolbar { toolbarContent }
            }
        }
        """,
        "README.md": """
        # Flotilla

        Run a fleet of coding agents side by side.

        ## Screenshots

        ![Fleet](docs/images/fleet-dark.png)
        """,
    ]

    static func sampleCommits(now: Date) -> [CommitSummary] {
        [
            CommitSummary(
                hash: "a3f9c21d8e7b6a5f4c3d2e1f0a9b8c7d6e5f4a3b", subject: "feat(fleet): unreachable banner",
                author: "Claude Code", date: now.addingTimeInterval(-300), isPushed: false,
                files: Array(sampleDiff.prefix(2))
            ),
            CommitSummary(
                hash: "7c1e0b9a8f7e6d5c4b3a2f1e0d9c8b7a6f5e4d3c", subject: "docs: dark README screenshots",
                author: "Sam Rivera", date: now.addingTimeInterval(-5_400), isPushed: true,
                files: [sampleDiff[2]]
            ),
            CommitSummary(
                hash: "e4d3c2b1a0f9e8d7c6b5a4f3e2d1c0b9a8f7e6d5", subject: "refactor(packages): multiplatform DesignSystem",
                author: "Sam Rivera", date: now.addingTimeInterval(-86_400), isPushed: true,
                files: [sampleDiff[1]]
            ),
        ]
    }
}

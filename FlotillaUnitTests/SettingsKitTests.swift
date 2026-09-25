import XCTest
import SettingsKit

final class SettingsKitTests: XCTestCase {
    private func makeIsolatedDefaults() -> UserDefaults {
        let suiteName = "flotilla-settings-tests-\(UUID().uuidString)"
        return UserDefaults(suiteName: suiteName)!
    }

    func testLoadWithNoSavedDataReturnsDefaultsWithProvidedWorktreeDirectory() {
        let store = UserDefaultsSettingsStore(defaults: makeIsolatedDefaults(), defaultWorktreeBaseDirectory: "/tmp/default-worktrees")
        let settings = store.load()
        XCTAssertEqual(settings.worktreeBaseDirectory, "/tmp/default-worktrees")
        XCTAssertEqual(settings.appearance, .system)
        XCTAssertEqual(settings.agentPaths, AgentPathOverrides())
    }

    func testSaveThenLoadRoundTripsAndOverwrites() {
        let defaults = makeIsolatedDefaults()
        let store = UserDefaultsSettingsStore(defaults: defaults, defaultWorktreeBaseDirectory: "/tmp/default-worktrees")

        var settings = AppSettings(worktreeBaseDirectory: "/tmp/default-worktrees")
        settings.agentPaths.claudeCodePath = "/opt/homebrew/bin/claude"
        settings.worktreeBaseDirectory = "/Users/dev/.flotilla/worktrees"
        settings.appearance = .dark
        store.save(settings)
        XCTAssertEqual(store.load(), settings)

        store.save(AppSettings(worktreeBaseDirectory: "/first", appearance: .light))
        store.save(AppSettings(worktreeBaseDirectory: "/second", appearance: .dark))
        let reloaded = store.load()
        XCTAssertEqual(reloaded.worktreeBaseDirectory, "/second")
        XCTAssertEqual(reloaded.appearance, .dark)
    }

    func testEphemeralStoreIgnoresSaves() {
        let store = EphemeralSettingsStore(defaultWorktreeBaseDirectory: "/tmp/ephemeral-worktrees")
        store.save(AppSettings(worktreeBaseDirectory: "/somewhere-else", appearance: .dark))
        let reloaded = store.load()
        XCTAssertEqual(reloaded.worktreeBaseDirectory, "/tmp/ephemeral-worktrees")
        XCTAssertEqual(reloaded.appearance, .system)
    }

    /// Older payloads must decode without silently resetting unrelated prefs.
    /// `SettingsStore` uses `try?`, so a single missing key that throws would
    /// wipe the whole file.
    func testLegacyPayloadsDecodeWithoutResettingUnrelatedSettings() throws {
        struct Case {
            let name: String
            let json: String
            let check: (AppSettings) throws -> Void
        }

        let payloads: [Case] = [
            Case(
                name: "pre-workspace/arguments",
                json: #"{"agentPaths":{"claudeCodePath":"/usr/local/bin/claude","codexCLIPath":""},"worktreeBaseDirectory":"/tmp/worktrees","appearance":"dark"}"#
            ) { decoded in
                XCTAssertEqual(decoded.agentPaths.claudeCodePath, "/usr/local/bin/claude")
                XCTAssertEqual(decoded.agentArguments, AgentArgumentOverrides())
                XCTAssertEqual(decoded.workspace, WorkspacePreferences())
            },
            Case(
                name: "pre-gpuRendering",
                json: #"{"worktreeBaseDirectory":"/tmp/worktrees","appearance":"dark","terminal":{"fontSize":16,"optionActsAsMeta":false,"naturalTextSelection":true,"scrollSpeed":1.5}}"#
            ) { decoded in
                XCTAssertEqual(decoded.terminal.gpuRendering, false)
                XCTAssertEqual(decoded.terminal.fontSize, 16)
                XCTAssertEqual(decoded.terminal.optionActsAsMeta, false)
                XCTAssertEqual(decoded.terminal.scrollSpeed, 1.5)
                XCTAssertEqual(decoded.appearance, .dark)
                XCTAssertEqual(decoded.worktreeBaseDirectory, "/tmp/worktrees")
            },
            Case(
                name: "pre-highlightUnseenCommits",
                json: #"{"worktreeBaseDirectory":"/tmp/worktrees","appearance":"dark","git":{"deleteBranchWithWorktree":false,"fetchBeforeCreatingWorktree":true}}"#
            ) { decoded in
                XCTAssertTrue(decoded.git.highlightUnseenCommits, "a new preference defaults to on")
                XCTAssertFalse(decoded.git.deleteBranchWithWorktree, "the existing choice must survive")
                XCTAssertTrue(decoded.git.fetchBeforeCreatingWorktree)
                XCTAssertEqual(decoded.appearance, .dark)
                XCTAssertEqual(decoded.worktreeBaseDirectory, "/tmp/worktrees")
            },
            Case(
                name: "pre-later sessionDefaults keys",
                json: #"{"worktreeBaseDirectory":"/tmp/worktrees","sessionDefaults":{"createWorktreeByDefault":false}}"#
            ) { decoded in
                XCTAssertEqual(decoded.sessionDefaults.createWorktreeByDefault, false)
                XCTAssertEqual(decoded.sessionDefaults.defaultAgentRawValue, "claudeCode")
            },
            Case(
                name: "removed launcherStyle ignored",
                json: #"{"sessionDefaults":{"launcherStyle":"sentence","createWorktreeByDefault":false}}"#
            ) { decoded in
                XCTAssertFalse(decoded.sessionDefaults.createWorktreeByDefault)
            },
            Case(
                name: "legacy positional agent int",
                json: #"{"sessionDefaults":{"defaultAgentRawValue":1}}"#
            ) { decoded in
                XCTAssertEqual(decoded.sessionDefaults.defaultAgentRawValue, "codexCLI")
            },
            Case(
                name: "legacy positional antigravity int",
                json: #"{"sessionDefaults":{"defaultAgentRawValue":3}}"#
            ) { decoded in
                XCTAssertEqual(decoded.sessionDefaults.defaultAgentRawValue, "antigravity")
            },
            Case(
                name: "legacy agentOverrides migration",
                json: #"""
                {
                    "agentPaths": {
                        "claudeCodePath": "/bin/claude",
                        "codexCLIPath": "/bin/codex"
                    },
                    "agentArguments": {
                        "claudeCodeArguments": ["--verbose"],
                        "openCodeArguments": ["--log-level", "debug"]
                    }
                }
                """#
            ) { decoded in
                XCTAssertEqual(decoded.agentOverrides.paths["claudeCode"], "/bin/claude")
                XCTAssertEqual(decoded.agentOverrides.paths["codexCLI"], "/bin/codex")
                XCTAssertEqual(decoded.agentOverrides.arguments["claudeCode"], ["--verbose"])
                XCTAssertEqual(decoded.agentOverrides.arguments["openCode"], ["--log-level", "debug"])
            },
            Case(
                name: "pre-namingSources merge defaults to agentManaged",
                json: #"{"worktreeBaseDirectory":"/tmp/worktrees","sessionDefaults":{"createWorktreeByDefault":false},"git":{"deleteBranchWithWorktree":false}}"#
            ) { decoded in
                XCTAssertEqual(decoded.sessionDefaults.namingSource, .agentManaged)
                XCTAssertEqual(decoded.sessionDefaults.createWorktreeByDefault, false)
                XCTAssertEqual(decoded.git.deleteBranchWithWorktree, false)
            },
            Case(
                name: "title naming wins over disagreeing worktree naming",
                json: #"{"sessionDefaults":{"agentManagedTitleEnabled":false},"git":{"worktreeNamingSource":"agentManaged"}}"#
            ) { decoded in
                XCTAssertEqual(decoded.sessionDefaults.namingSource, .promptDerived)
            },
            Case(
                name: "legacy worktree naming carries over alone",
                json: #"{"git":{"worktreeNamingSource":"agentManaged"}}"#
            ) { decoded in
                XCTAssertEqual(decoded.sessionDefaults.namingSource, .agentManaged)
            },
            Case(
                name: "pre-notification delivery defaults to always",
                json: #"{"worktreeBaseDirectory":"/tmp/worktrees","notifications":{"waitingForInputEnabled":true,"finishedEnabled":false}}"#
            ) { decoded in
                XCTAssertEqual(decoded.notifications.delivery, .always)
                XCTAssertTrue(decoded.notifications.waitingForInputEnabled)
                XCTAssertFalse(decoded.notifications.finishedEnabled)
                XCTAssertEqual(decoded.worktreeBaseDirectory, "/tmp/worktrees")
            },
            Case(
                name: "pre-accentColor defaults to original",
                json: #"{"worktreeBaseDirectory":"/tmp/worktrees","appearance":"dark"}"#
            ) { decoded in
                XCTAssertEqual(decoded.accentColor, "original")
            },
        ]

        for entry in payloads {
            let decoded = try JSONDecoder().decode(AppSettings.self, from: Data(entry.json.utf8))
            try entry.check(decoded)
        }

        XCTAssertEqual(AppSettings().sessionDefaults.namingSource, .appleIntelligence)
    }

    func testNotificationDeliveryBehavior() {
        var prefs = NotificationPreferences()
        XCTAssertEqual(prefs.delivery, .always)
        XCTAssertTrue(prefs.waitingForInputEnabled)
        XCTAssertTrue(prefs.finishedEnabled)
        XCTAssertTrue(prefs.isConfiguredToNotify)

        prefs.delivery = .never
        XCTAssertFalse(prefs.shouldDeliver(isActive: true))
        XCTAssertFalse(prefs.shouldDeliver(isActive: false))
        XCTAssertFalse(prefs.shouldNotifyWaitingForInput(isActive: true))
        XCTAssertFalse(prefs.shouldNotifyWaitingForInput(isActive: false))
        XCTAssertFalse(prefs.shouldNotifySessionFinished(isActive: true))
        XCTAssertFalse(prefs.shouldNotifySessionFinished(isActive: false))
        XCTAssertFalse(prefs.isConfiguredToNotify)

        prefs.delivery = .onlyWhenNotActive
        XCTAssertFalse(prefs.shouldDeliver(isActive: true))
        XCTAssertTrue(prefs.shouldDeliver(isActive: false))
        XCTAssertFalse(prefs.shouldNotifyWaitingForInput(isActive: true))
        XCTAssertTrue(prefs.shouldNotifyWaitingForInput(isActive: false))
        XCTAssertFalse(prefs.shouldNotifySessionFinished(isActive: true))
        XCTAssertTrue(prefs.shouldNotifySessionFinished(isActive: false))
        XCTAssertTrue(prefs.isConfiguredToNotify)

        prefs.delivery = .always
        XCTAssertTrue(prefs.shouldDeliver(isActive: true))
        XCTAssertTrue(prefs.shouldDeliver(isActive: false))
        XCTAssertTrue(prefs.shouldNotifyWaitingForInput(isActive: true))
        XCTAssertTrue(prefs.shouldNotifyWaitingForInput(isActive: false))
        XCTAssertTrue(prefs.shouldNotifySessionFinished(isActive: true))
        XCTAssertTrue(prefs.shouldNotifySessionFinished(isActive: false))
        XCTAssertTrue(prefs.isConfiguredToNotify)

        prefs.waitingForInputEnabled = false
        XCTAssertFalse(prefs.shouldNotifyWaitingForInput(isActive: true))
        XCTAssertFalse(prefs.shouldNotifyWaitingForInput(isActive: false))
        XCTAssertTrue(prefs.shouldNotifySessionFinished(isActive: false))

        prefs.finishedEnabled = false
        XCTAssertFalse(prefs.isConfiguredToNotify)
    }
}

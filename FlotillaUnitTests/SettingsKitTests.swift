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

    func testSaveThenLoadRoundTrips() {
        let defaults = makeIsolatedDefaults()
        let store = UserDefaultsSettingsStore(defaults: defaults, defaultWorktreeBaseDirectory: "/tmp/default-worktrees")

        var settings = AppSettings(worktreeBaseDirectory: "/tmp/default-worktrees")
        settings.agentPaths.claudeCodePath = "/opt/homebrew/bin/claude"
        settings.worktreeBaseDirectory = "/Users/dev/.flotilla/worktrees"
        settings.appearance = .dark
        store.save(settings)

        let reloaded = store.load()
        XCTAssertEqual(reloaded, settings)
    }

    func testSaveOverwritesPreviousValue() {
        let defaults = makeIsolatedDefaults()
        let store = UserDefaultsSettingsStore(defaults: defaults, defaultWorktreeBaseDirectory: "/tmp/default-worktrees")

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

    func testOlderSettingsPayloadDecodesWithNewWorkspaceAndArgumentDefaults() throws {
        let oldJSON = Data(#"{"agentPaths":{"claudeCodePath":"/usr/local/bin/claude","codexCLIPath":""},"worktreeBaseDirectory":"/tmp/worktrees","appearance":"dark"}"#.utf8)

        let decoded = try JSONDecoder().decode(AppSettings.self, from: oldJSON)

        XCTAssertEqual(decoded.agentPaths.claudeCodePath, "/usr/local/bin/claude")
        XCTAssertEqual(decoded.agentArguments, AgentArgumentOverrides())
        XCTAssertEqual(decoded.workspace, WorkspacePreferences())
    }

    /// `TerminalPreferences` gained `gpuRendering` after users could already
    /// have a `terminal` object persisted without it. `AppSettings` is
    /// decoded with `try?` (`SettingsStoring.load`), so if `gpuRendering`
    /// were a synthesized, throwing-on-missing-key property, an old settings
    /// file would fail to decode entirely and silently reset every setting —
    /// not just this one. This must decode cleanly and default to `false`,
    /// with the rest of `terminal` (and the surrounding settings) intact.
    func testSettingsWrittenBeforeGPURenderingStillDecode() throws {
        let oldJSON = Data(
            #"{"worktreeBaseDirectory":"/tmp/worktrees","appearance":"dark","terminal":{"fontSize":16,"optionActsAsMeta":false,"naturalTextSelection":true,"scrollSpeed":1.5}}"#.utf8
        )

        let decoded = try JSONDecoder().decode(AppSettings.self, from: oldJSON)

        XCTAssertEqual(decoded.terminal.gpuRendering, false)
        XCTAssertEqual(decoded.terminal.fontSize, 16)
        XCTAssertEqual(decoded.terminal.optionActsAsMeta, false)
        XCTAssertEqual(decoded.terminal.scrollSpeed, 1.5)
        XCTAssertEqual(decoded.appearance, .dark)
        XCTAssertEqual(decoded.worktreeBaseDirectory, "/tmp/worktrees")
    }

    /// `GitPreferences` gained `highlightUnseenCommits`. It decodes key-by-key
    /// precisely so an older payload keeps its other git settings — `SettingsStore`
    /// discards the whole file on any decode error, so a single missing key
    /// would otherwise silently reset every unrelated preference.
    func testSettingsWrittenBeforeUnseenCommitHighlightingStillDecode() throws {
        let oldJSON = Data(
            #"{"worktreeBaseDirectory":"/tmp/worktrees","appearance":"dark","git":{"deleteBranchWithWorktree":false,"fetchBeforeCreatingWorktree":true}}"#.utf8
        )

        let decoded = try JSONDecoder().decode(AppSettings.self, from: oldJSON)

        XCTAssertTrue(decoded.git.highlightUnseenCommits, "a new preference defaults to on")
        XCTAssertFalse(decoded.git.deleteBranchWithWorktree, "the existing choice must survive")
        XCTAssertTrue(decoded.git.fetchBeforeCreatingWorktree)
        XCTAssertEqual(decoded.appearance, .dark, "unrelated settings must not be reset")
        XCTAssertEqual(decoded.worktreeBaseDirectory, "/tmp/worktrees")
    }

    /// `SessionDefaults` decodes key-by-key: a payload written before any
    /// later-added key must still decode without resetting the rest.
    func testSettingsWrittenBeforeLaterSessionDefaultsStillDecode() throws {
        let oldJSON = Data(
            #"{"worktreeBaseDirectory":"/tmp/worktrees","sessionDefaults":{"createWorktreeByDefault":false}}"#.utf8
        )

        let decoded = try JSONDecoder().decode(AppSettings.self, from: oldJSON)

        XCTAssertEqual(decoded.sessionDefaults.createWorktreeByDefault, false)
        XCTAssertEqual(decoded.sessionDefaults.defaultAgentRawValue, "claudeCode")
    }

    func testRemovedLauncherStyleDoesNotInvalidateStoredSessionDefaults() throws {
        let stored = Data(#"{"sessionDefaults":{"launcherStyle":"sentence","createWorktreeByDefault":false}}"#.utf8)

        let decoded = try JSONDecoder().decode(AppSettings.self, from: stored)

        XCTAssertFalse(decoded.sessionDefaults.createWorktreeByDefault)
    }

    func testLegacySessionDefaultsPositionalIntDecodesToString() throws {
        let json = Data(#"{"sessionDefaults":{"defaultAgentRawValue":1}}"#.utf8)
        let decoded = try JSONDecoder().decode(AppSettings.self, from: json)
        XCTAssertEqual(decoded.sessionDefaults.defaultAgentRawValue, "codexCLI")

        let jsonAntigravity = Data(#"{"sessionDefaults":{"defaultAgentRawValue":3}}"#.utf8)
        let decodedAntigravity = try JSONDecoder().decode(AppSettings.self, from: jsonAntigravity)
        XCTAssertEqual(decodedAntigravity.sessionDefaults.defaultAgentRawValue, "antigravity")
    }

    func testLegacyAgentOverridesMigration() throws {
        let legacyJSON = Data(#"""
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
        """#.utf8)

        let decoded = try JSONDecoder().decode(AppSettings.self, from: legacyJSON)
        XCTAssertEqual(decoded.agentOverrides.paths["claudeCode"], "/bin/claude")
        XCTAssertEqual(decoded.agentOverrides.paths["codexCLI"], "/bin/codex")
        XCTAssertEqual(decoded.agentOverrides.arguments["claudeCode"], ["--verbose"])
        XCTAssertEqual(decoded.agentOverrides.arguments["openCode"], ["--log-level", "debug"])
    }

    func testSettingsWrittenBeforeNamingSourcesWereMergedStillDecode() throws {
        let oldJSON = Data(
            #"{"worktreeBaseDirectory":"/tmp/worktrees","sessionDefaults":{"createWorktreeByDefault":false},"git":{"deleteBranchWithWorktree":false}}"#.utf8
        )

        let decoded = try JSONDecoder().decode(AppSettings.self, from: oldJSON)

        // Neither the new merged key nor either legacy naming key is present
        // anywhere, so this falls through to the oldest default (the
        // pre-enum boolean's default of `true`, i.e. agent-managed).
        XCTAssertEqual(decoded.sessionDefaults.namingSource, .agentManaged)
        XCTAssertEqual(decoded.sessionDefaults.createWorktreeByDefault, false)
        XCTAssertEqual(decoded.git.deleteBranchWithWorktree, false)
    }

    func testNewSettingsDefaultToAppleIntelligence() throws {
        let fresh = AppSettings()
        XCTAssertEqual(fresh.sessionDefaults.namingSource, .appleIntelligence)
    }

    /// Before the merge, title and worktree naming were two independent
    /// settings that could disagree — e.g. an Apple-Intelligence title next
    /// to an agent-managed worktree. Flotilla would resolve the title
    /// synchronously before spawning the agent, then discard it and have the
    /// agent invent an unrelated slug for the worktree it created itself.
    /// The merge collapses both into one setting; when an old settings file
    /// has both legacy keys and they disagree, the title's value wins.
    func testExplicitTitleNamingSourceWinsOverDisagreeingLegacyWorktreeNamingSource() throws {
        let saved = Data(#"{"sessionDefaults":{"agentManagedTitleEnabled":false},"git":{"worktreeNamingSource":"agentManaged"}}"#.utf8)
        let decoded = try JSONDecoder().decode(AppSettings.self, from: saved)
        XCTAssertEqual(decoded.sessionDefaults.namingSource, .promptDerived)
    }

    /// When the old settings file has no title-naming signal at all — not
    /// even the oldest boolean toggle — but does have the legacy worktree
    /// key, that value carries over instead of silently reverting to the
    /// fresh default.
    func testLegacyWorktreeNamingSourceCarriesOverWhenTitleWasNeverSet() throws {
        let saved = Data(#"{"git":{"worktreeNamingSource":"agentManaged"}}"#.utf8)
        let decoded = try JSONDecoder().decode(AppSettings.self, from: saved)
        XCTAssertEqual(decoded.sessionDefaults.namingSource, .agentManaged)
    }

    func testNotificationDeliveryDefaultsAndDisplayName() {
        let prefs = NotificationPreferences()
        XCTAssertEqual(prefs.delivery, .always)
        XCTAssertTrue(prefs.waitingForInputEnabled)
        XCTAssertTrue(prefs.finishedEnabled)
        XCTAssertTrue(prefs.isConfiguredToNotify)

        XCTAssertEqual(NotificationDelivery.never.displayName, "Never")
        XCTAssertEqual(NotificationDelivery.onlyWhenNotActive.displayName, "Only when not active")
        XCTAssertEqual(NotificationDelivery.always.displayName, "Always")
    }

    func testNotificationDeliveryBehavior() {
        var prefs = NotificationPreferences(delivery: .never)
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

        // Event toggle turned off suppresses even if delivery is always
        prefs.waitingForInputEnabled = false
        XCTAssertFalse(prefs.shouldNotifyWaitingForInput(isActive: true))
        XCTAssertFalse(prefs.shouldNotifyWaitingForInput(isActive: false))
        XCTAssertTrue(prefs.shouldNotifySessionFinished(isActive: false))

        prefs.finishedEnabled = false
        XCTAssertFalse(prefs.isConfiguredToNotify)
    }

    func testSettingsWrittenBeforeNotificationDeliveryStillDecode() throws {
        let oldJSON = Data(
            #"{"worktreeBaseDirectory":"/tmp/worktrees","notifications":{"waitingForInputEnabled":true,"finishedEnabled":false}}"#.utf8
        )

        let decoded = try JSONDecoder().decode(AppSettings.self, from: oldJSON)

        XCTAssertEqual(decoded.notifications.delivery, .always, "a missing delivery setting defaults to always")
        XCTAssertTrue(decoded.notifications.waitingForInputEnabled)
        XCTAssertFalse(decoded.notifications.finishedEnabled)
        XCTAssertEqual(decoded.worktreeBaseDirectory, "/tmp/worktrees")
    }

    func testNotificationDeliveryRoundTrip() throws {
        for delivery in NotificationDelivery.allCases {
            var settings = AppSettings()
            settings.notifications.delivery = delivery
            let encoded = try JSONEncoder().encode(settings)
            let decoded = try JSONDecoder().decode(AppSettings.self, from: encoded)
            XCTAssertEqual(decoded.notifications.delivery, delivery)
        }
    }
}

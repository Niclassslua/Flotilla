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

    func testSettingsWrittenBeforeWorktreeNamingSourceAndAgentManagedTitlesStillDecode() throws {
        let oldJSON = Data(
            #"{"worktreeBaseDirectory":"/tmp/worktrees","sessionDefaults":{"createWorktreeByDefault":false},"git":{"deleteBranchWithWorktree":false}}"#.utf8
        )

        let decoded = try JSONDecoder().decode(AppSettings.self, from: oldJSON)

        XCTAssertEqual(decoded.git.worktreeNamingSource, .promptDerived)
        XCTAssertEqual(decoded.sessionDefaults.agentManagedTitleEnabled, true)
        XCTAssertEqual(decoded.sessionDefaults.createWorktreeByDefault, false)
        XCTAssertEqual(decoded.git.deleteBranchWithWorktree, false)
    }

}

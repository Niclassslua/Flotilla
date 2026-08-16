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
}

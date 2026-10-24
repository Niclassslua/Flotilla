import XCTest
import SessionKit
import SettingsKit
import GitKit
import PersistenceKit
@testable import Flotilla

@MainActor
final class OnboardingTests: XCTestCase {
    func testCompletionSurvivesSettingsRoundTripAndUpdates() throws {
        var settings = AppSettings(appearance: .dark)
        XCTAssertTrue(OnboardingSheet.shouldPresent(settings: settings, environment: [:]))
        settings.onboardingVersion = OnboardingSheet.currentVersion
        settings.sessionDefaults.setEnabledAgents([.codexCLI])
        let restored = try JSONDecoder().decode(AppSettings.self, from: JSONEncoder().encode(settings))
        XCTAssertFalse(OnboardingSheet.shouldPresent(settings: restored, environment: [:]))
        XCTAssertEqual(restored.sessionDefaults.enabledAgents, [.codexCLI])
        XCTAssertEqual(restored.sessionDefaults.defaultAgentRawValue, AgentKind.codexCLI.rawValue)
        XCTAssertEqual(restored.appearance, .dark)
    }

    func testLegacySettingsKeepPreferencesAndExistingUsersSkipIntro() throws {
        var settings = try JSONDecoder().decode(AppSettings.self, from: Data(#"{"appearance":"dark","worktreeBaseDirectory":"/kept"}"#.utf8))
        XCTAssertEqual(settings.sessionDefaults.enabledAgents, AgentKind.allCases)
        OnboardingSheet.markExistingUser(settings: &settings, hasWorkspace: true)
        XCTAssertFalse(OnboardingSheet.shouldPresent(settings: settings, environment: [:]))
        XCTAssertEqual(settings.worktreeBaseDirectory, "/kept")
        XCTAssertEqual(settings.appearance, .dark)
        settings.sessionDefaults.setEnabledAgents([])
        XCTAssertEqual(settings.sessionDefaults.enabledAgents, AgentKind.allCases)
    }

    func testFreshWorkspaceStillGetsIntroAndChosenAgentsCannotBeEmpty() {
        var settings = AppSettings()
        OnboardingSheet.markExistingUser(settings: &settings, hasWorkspace: false)
        XCTAssertTrue(OnboardingSheet.shouldPresent(settings: settings, environment: [:]))
        let draft = OnboardingDraft(detectedAgents: [.codexCLI], missingTools: [])
        draft.toggle(.codexCLI)
        XCTAssertEqual(draft.orderedEnabledAgents, [.codexCLI])
    }

    func testDeniedNotificationRequestLeavesSwitchOff() async {
        let draft = OnboardingDraft(detectedAgents: [.codexCLI], missingTools: [], requestNotificationAuthorization: { false })
        await draft.setNotificationsEnabled(true)
        XCTAssertFalse(draft.notificationsEnabled)
        XCTAssertTrue(draft.notificationsDenied)
    }
    func testOpenLauncherDropsDisabledAgentAndItsModel() throws {
        var settings = AppSettings()
        let store = AppStore(
            repository: try GRDBSessionRepository(),
            gitService: MockGitService(),
            processManager: SessionProcessManager(locator: SelectiveExecutableLocator(availableNames: []), processFactory: RecordingProcessFactory()),
            worktreeBaseDirectoryProvider: { URL(fileURLWithPath: "/tmp/onboarding-tests") },
            settingsProvider: { settings }
        )
        let draft = SessionDraft(store: store, initialProject: nil, initialGoal: "test", createWorktreeByDefault: false, fetchBeforeCreatingWorktree: false, defaultAgent: .claudeCode, openCodeSubscription: .none)
        draft.model = "claude-only-model"
        settings.sessionDefaults.setEnabledAgents([.codexCLI])
        draft.syncEnabledAgent()
        XCTAssertEqual(draft.agent, .codexCLI)
        XCTAssertEqual(draft.model, "")
    }

}

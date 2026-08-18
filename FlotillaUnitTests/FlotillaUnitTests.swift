import XCTest
import SessionKit
import AgentKit
import SettingsKit

final class AgentProviderTests: XCTestCase {
    func testRegistryMapsEveryAgentToItsExpectedExecutable() {
        let registry = AgentProviderRegistry()

        XCTAssertEqual(registry.provider(for: .claudeCode).binaryName, "claude")
        XCTAssertEqual(registry.provider(for: .codexCLI).binaryName, "codex")
        XCTAssertEqual(registry.provider(for: .openCode).binaryName, "opencode")
        XCTAssertEqual(registry.provider(for: .antigravity).binaryName, "agy")
    }

    func testLaunchPlanUsesConfiguredPathArgumentsAndInteractiveGoal() {
        var settings = AppSettings()
        settings.agentPaths.codexCLIPath = "/opt/homebrew/bin/codex"
        settings.agentArguments.codexCLIArguments = ["--model", "gpt-5"]

        let plan = AgentProviderRegistry().provider(for: .codexCLI).launchPlan(
            goal: "  Repair the build  ",
            settings: settings,
            baseEnvironment: ["PATH": "/bin"]
        )

        XCTAssertEqual(plan.configuredPath, "/opt/homebrew/bin/codex")
        XCTAssertEqual(plan.arguments, ["--model", "gpt-5"])
        XCTAssertEqual(plan.initialInput, Data("Repair the build\r".utf8))
        XCTAssertEqual(plan.environment["TERM"], "xterm-256color")
        XCTAssertEqual(plan.environment["COLORTERM"], "truecolor")
        XCTAssertTrue(plan.environment["PATH"]?.contains("/opt/homebrew/bin") == true)
        XCTAssertTrue(plan.environment["PATH"]?.contains("/.local/bin") == true)
    }

    /// GUI-launched apps (Finder, or Xcode's debugger) inherit `TERM=dumb`
    /// from launchd rather than a shell. Left untouched, that value reaches
    /// the agent CLI's color-support detection and renders the terminal in
    /// black and white.
    func testLaunchPlanReplacesUnusableDumbTerm() {
        let plan = AgentProviderRegistry().provider(for: .claudeCode).launchPlan(
            goal: nil,
            settings: AppSettings(),
            baseEnvironment: ["TERM": "dumb"]
        )

        XCTAssertEqual(plan.environment["TERM"], "xterm-256color")
    }

    func testLaunchPlanAppendsPerSessionModelAfterConfiguredArguments() {
        var settings = AppSettings()
        settings.agentArguments.claudeCodeArguments = ["--permission-mode", "acceptEdits"]

        let plan = AgentProviderRegistry().provider(for: .claudeCode).launchPlan(
            goal: nil,
            model: "  sonnet  ",
            settings: settings,
            baseEnvironment: [:]
        )

        XCTAssertEqual(plan.arguments, ["--permission-mode", "acceptEdits", "--model", "sonnet"])
    }

    func testLaunchPlanOmitsModelFlagWhenModelIsNilOrBlank() {
        let planWithNilModel = AgentProviderRegistry().provider(for: .claudeCode).launchPlan(
            goal: nil,
            model: nil,
            settings: AppSettings(),
            baseEnvironment: [:]
        )
        let planWithBlankModel = AgentProviderRegistry().provider(for: .claudeCode).launchPlan(
            goal: nil,
            model: "   ",
            settings: AppSettings(),
            baseEnvironment: [:]
        )

        XCTAssertEqual(planWithNilModel.arguments, [])
        XCTAssertEqual(planWithBlankModel.arguments, [])
    }

    func testClaudeLaunchPlanUsesNativeEffortFlag() {
        let plan = AgentProviderRegistry().provider(for: .claudeCode).launchPlan(
            goal: nil,
            model: "sonnet",
            effort: .high,
            settings: AppSettings(),
            baseEnvironment: [:]
        )

        XCTAssertEqual(plan.arguments, ["--model", "sonnet", "--effort", "high"])
    }

    func testCodexLaunchPlanUsesPerRunReasoningEffortOverride() {
        let plan = AgentProviderRegistry().provider(for: .codexCLI).launchPlan(
            goal: nil,
            model: nil,
            effort: .xhigh,
            settings: AppSettings(),
            baseEnvironment: [:]
        )

        XCTAssertEqual(plan.arguments, ["--config", "model_reasoning_effort=\"xhigh\""])
    }

    func testAntigravityLaunchPlanUsesNativeEffortFlag() {
        let plan = AgentProviderRegistry().provider(for: .antigravity).launchPlan(
            goal: nil,
            model: "gemini-2.5-pro",
            effort: .high,
            settings: AppSettings(),
            baseEnvironment: [:]
        )

        XCTAssertEqual(plan.arguments, ["--model", "gemini-2.5-pro", "--effort", "high"])
    }

    func testOpenCodeLaunchPlanIgnoresUnsupportedEffort() {
        let plan = AgentProviderRegistry().provider(for: .openCode).launchPlan(
            goal: nil,
            model: nil,
            effort: .high,
            settings: AppSettings(),
            baseEnvironment: [:]
        )

        XCTAssertEqual(plan.arguments, [])
    }

    func testLaunchPlanDoesNotInventCredentialEnvironmentVariables() {
        let inherited = ["PATH": "/bin", "EXISTING": "preserved"]
        let plan = AgentProviderRegistry().provider(for: .claudeCode).launchPlan(
            goal: nil,
            settings: AppSettings(),
            baseEnvironment: inherited
        )

        XCTAssertEqual(plan.environment["EXISTING"], "preserved")
        XCTAssertNil(plan.environment["ANTHROPIC_API_KEY"])
        XCTAssertNil(plan.environment["OPENAI_API_KEY"])
        XCTAssertNil(plan.initialInput)
    }
}

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
        XCTAssertEqual(plan.arguments, ["--model", "gpt-5", "Repair the build"])
        XCTAssertNil(plan.initialInput)
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

    func testAntigravityLaunchPlanOmitsEffortFlag() {
        let plan = AgentProviderRegistry().provider(for: .antigravity).launchPlan(
            goal: nil,
            model: "gemini-2.5-pro",
            effort: .high,
            settings: AppSettings(),
            baseEnvironment: [:]
        )

        XCTAssertEqual(plan.arguments, ["--model", "gemini-2.5-pro"])
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

    func testClaudeLaunchPlanWithResumeIntent() {
        let provider = AgentProviderRegistry().provider(for: .claudeCode)
        let freshPlan = provider.launchPlan(
            goal: nil,
            resumeIntent: .freshWithAssignedIdentity("test-uuid-123"),
            settings: AppSettings(),
            baseEnvironment: [:]
        )
        XCTAssertEqual(freshPlan.arguments, ["--session-id", "test-uuid-123"])

        let resumePlan = provider.launchPlan(
            goal: nil,
            resumeIntent: .resume("test-uuid-123"),
            settings: AppSettings(),
            baseEnvironment: [:]
        )
        XCTAssertEqual(resumePlan.arguments, ["--resume", "test-uuid-123"])
    }

    func testCodexLaunchPlanWithResumeIntent() {
        let provider = AgentProviderRegistry().provider(for: .codexCLI)
        var settings = AppSettings()
        settings.agentOverrides.arguments["codexCLI"] = ["--verbose"]

        let plainPlan = provider.launchPlan(
            goal: nil,
            resumeIntent: .none,
            settings: settings,
            baseEnvironment: [:]
        )
        XCTAssertEqual(plainPlan.arguments, ["--verbose"])

        let resumePlan = provider.launchPlan(
            goal: nil,
            resumeIntent: .resume("01932f14-0000-7000-8000-000000000000"),
            settings: settings,
            baseEnvironment: [:]
        )
        XCTAssertEqual(resumePlan.arguments, ["resume", "01932f14-0000-7000-8000-000000000000", "--verbose"])
    }

    func testOpenCodeLaunchPlanWithResumeIntent() {
        let provider = AgentProviderRegistry().provider(for: .openCode)
        let resumePlan = provider.launchPlan(
            goal: nil,
            resumeIntent: .resume("ses_abc123"),
            settings: AppSettings(),
            baseEnvironment: [:]
        )
        XCTAssertEqual(resumePlan.arguments, ["--session", "ses_abc123"])
    }

    func testAntigravityLaunchPlanWithResumeIntent() {
        let provider = AgentProviderRegistry().provider(for: .antigravity)
        let resumePlan = provider.launchPlan(
            goal: nil,
            resumeIntent: .resume("conv-xyz789"),
            settings: AppSettings(),
            baseEnvironment: [:]
        )
        XCTAssertEqual(resumePlan.arguments, ["--conversation", "conv-xyz789"])
    }

    func testClaudeLaunchPlanAppendsPositionalPrompt() {
        let provider = AgentProviderRegistry().provider(for: .claudeCode)
        let plan = provider.launchPlan(
            goal: "Investigate crash in renderer",
            model: "sonnet",
            effort: .high,
            resumeIntent: .freshWithAssignedIdentity("uuid-1234"),
            settings: AppSettings(),
            baseEnvironment: [:]
        )

        XCTAssertEqual(plan.arguments, [
            "--model", "sonnet",
            "--effort", "high",
            "--session-id", "uuid-1234",
            "Investigate crash in renderer"
        ])
        XCTAssertNil(plan.initialInput)
    }

    func testCodexLaunchPlanAppendsPositionalPrompt() {
        let provider = AgentProviderRegistry().provider(for: .codexCLI)
        let plan = provider.launchPlan(
            goal: "Write unit tests for parser",
            model: "gpt-5.5",
            effort: .xhigh,
            resumeIntent: .none,
            settings: AppSettings(),
            baseEnvironment: [:]
        )

        XCTAssertEqual(plan.arguments, [
            "--model", "gpt-5.5",
            "--config", "model_reasoning_effort=\"xhigh\"",
            "Write unit tests for parser"
        ])
        XCTAssertNil(plan.initialInput)
    }

    func testOpenCodeLaunchPlanAppendsPromptFlag() {
        let provider = AgentProviderRegistry().provider(for: .openCode)
        let plan = provider.launchPlan(
            goal: "Refactor database migrations",
            model: "opencode/deepseek-v4-flash-free",
            resumeIntent: .none,
            settings: AppSettings(),
            baseEnvironment: [:]
        )

        XCTAssertEqual(plan.arguments, [
            "--model", "opencode/deepseek-v4-flash-free",
            "--prompt", "Refactor database migrations"
        ])
        XCTAssertNil(plan.initialInput)
    }

    func testAntigravityLaunchPlanAppendsInteractivePromptFlag() {
        let provider = AgentProviderRegistry().provider(for: .antigravity)
        let plan = provider.launchPlan(
            goal: "Fix layout bug in sidebar",
            model: "gemini-3.7-flash-high",
            effort: .medium,
            resumeIntent: .none,
            settings: AppSettings(),
            baseEnvironment: [:]
        )

        XCTAssertEqual(plan.arguments, [
            "--model", "gemini-3.7-flash-high",
            "--prompt-interactive", "Fix layout bug in sidebar"
        ])
        XCTAssertNil(plan.initialInput)
    }

    func testOpenCodeLaunchPlanWithPlanModeUsesAgentFlag() {
        let provider = AgentProviderRegistry().provider(for: .openCode)
        let plan = provider.launchPlan(
            goal: "Refactor database migrations",
            model: "opencode/deepseek-v4-flash-free",
            mode: .plan,
            resumeIntent: .none,
            settings: AppSettings(),
            baseEnvironment: [:]
        )

        XCTAssertEqual(plan.arguments, [
            "--model", "opencode/deepseek-v4-flash-free",
            "--agent", "plan",
            "--prompt", "Refactor database migrations"
        ])
        XCTAssertNil(plan.initialInput)
    }

    func testClaudeLaunchPlanWithPlanModeUsesPermissionMode() {
        let provider = AgentProviderRegistry().provider(for: .claudeCode)
        let plan = provider.launchPlan(
            goal: "Refactor database migrations",
            model: "sonnet",
            mode: .plan,
            resumeIntent: .none,
            settings: AppSettings(),
            baseEnvironment: [:]
        )

        XCTAssertEqual(plan.arguments, [
            "--model", "sonnet",
            "--permission-mode", "plan",
            "Refactor database migrations"
        ])
        XCTAssertNil(plan.initialInput)
    }

    func testAntigravityLaunchPlanWithPlanModeUsesModeFlag() {
        let provider = AgentProviderRegistry().provider(for: .antigravity)
        let plan = provider.launchPlan(
            goal: "Refactor database migrations",
            model: "gemini-3.7-flash-high",
            mode: .plan,
            resumeIntent: .none,
            settings: AppSettings(),
            baseEnvironment: [:]
        )

        XCTAssertEqual(plan.arguments, [
            "--model", "gemini-3.7-flash-high",
            "--mode", "plan",
            "--prompt-interactive", "Refactor database migrations"
        ])
        XCTAssertNil(plan.initialInput)
    }

    func testCodexLaunchPlanWithPlanModeDeliversViaInitialInput() {
        let provider = AgentProviderRegistry().provider(for: .codexCLI)
        let plan = provider.launchPlan(
            goal: "Refactor database migrations",
            model: "gpt-5.5",
            mode: .plan,
            resumeIntent: .none,
            settings: AppSettings(),
            baseEnvironment: [:]
        )

        XCTAssertEqual(plan.arguments, ["--model", "gpt-5.5"])
        XCTAssertEqual(plan.initialInput, "/plan Refactor database migrations\n".data(using: .utf8))
    }

    func testLaunchPlanOmitsPromptFlagWhenGoalIsNilOrBlank() {
        let provider = AgentProviderRegistry().provider(for: .claudeCode)
        let planWithNil = provider.launchPlan(
            goal: nil,
            model: "sonnet",
            resumeIntent: .none,
            settings: AppSettings(),
            baseEnvironment: [:]
        )
        let planWithBlank = provider.launchPlan(
            goal: "   \n\t  ",
            model: "sonnet",
            resumeIntent: .none,
            settings: AppSettings(),
            baseEnvironment: [:]
        )

        XCTAssertEqual(planWithNil.arguments, ["--model", "sonnet"])
        XCTAssertEqual(planWithBlank.arguments, ["--model", "sonnet"])
        XCTAssertNil(planWithNil.initialInput)
        XCTAssertNil(planWithBlank.initialInput)
    }

    func testLaunchPlanOmitsPromptFlagOnResumeEvenWithGoal() {
        let provider = AgentProviderRegistry().provider(for: .claudeCode)
        let resumePlan = provider.launchPlan(
            goal: "Some previous goal",
            resumeIntent: .resume("sess-abc"),
            settings: AppSettings(),
            baseEnvironment: [:]
        )

        XCTAssertEqual(resumePlan.arguments, ["--resume", "sess-abc"])
        XCTAssertNil(resumePlan.initialInput)
    }

    func testLaunchPlanPreservesMultilinePrompt() {
        let provider = AgentProviderRegistry().provider(for: .claudeCode)
        let multilineGoal = "Line 1: implement feature\nLine 2: ensure tests pass\nLine 3: add documentation"
        let plan = provider.launchPlan(
            goal: multilineGoal,
            resumeIntent: .none,
            settings: AppSettings(),
            baseEnvironment: [:]
        )

        XCTAssertEqual(plan.arguments, [multilineGoal])
        XCTAssertNil(plan.initialInput)
    }
}

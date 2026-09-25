import XCTest
import SessionKit
import AgentKit
import SettingsKit

final class AgentProviderTests: XCTestCase {
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

    func testLaunchPlanEncodesEffortPerAgent() {
        let registry = AgentProviderRegistry()
        let cases: [(AgentKind, String?, AgentEffort, [String])] = [
            (.claudeCode, "sonnet", .high, ["--model", "sonnet", "--effort", "high"]),
            (.codexCLI, nil, .xhigh, ["--config", "model_reasoning_effort=\"xhigh\""]),
            (.antigravity, "gemini-2.5-pro", .high, ["--model", "gemini-2.5-pro"]),
            (.openCode, nil, .high, []),
        ]
        for entry in cases {
            let plan = registry.provider(for: entry.0).launchPlan(
                goal: nil,
                model: entry.1,
                effort: entry.2,
                settings: AppSettings(),
                baseEnvironment: [:]
            )
            XCTAssertEqual(plan.arguments, entry.3, "\(entry.0)")
        }
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

    func testLaunchPlanResumeIntentPerAgent() {
        let registry = AgentProviderRegistry()

        let claude = registry.provider(for: .claudeCode)
        XCTAssertEqual(
            claude.launchPlan(goal: nil, resumeIntent: .freshWithAssignedIdentity("test-uuid-123"), settings: AppSettings(), baseEnvironment: [:]).arguments,
            ["--session-id", "test-uuid-123"]
        )
        XCTAssertEqual(
            claude.launchPlan(goal: nil, resumeIntent: .resume("test-uuid-123"), settings: AppSettings(), baseEnvironment: [:]).arguments,
            ["--resume", "test-uuid-123"]
        )

        var codexSettings = AppSettings()
        codexSettings.agentOverrides.arguments["codexCLI"] = ["--verbose"]
        let codex = registry.provider(for: .codexCLI)
        XCTAssertEqual(
            codex.launchPlan(goal: nil, resumeIntent: .none, settings: codexSettings, baseEnvironment: [:]).arguments,
            ["--verbose"]
        )
        XCTAssertEqual(
            codex.launchPlan(goal: nil, resumeIntent: .resume("01932f14-0000-7000-8000-000000000000"), settings: codexSettings, baseEnvironment: [:]).arguments,
            ["resume", "01932f14-0000-7000-8000-000000000000", "--verbose"]
        )

        XCTAssertEqual(
            registry.provider(for: .openCode).launchPlan(goal: nil, resumeIntent: .resume("ses_abc123"), settings: AppSettings(), baseEnvironment: [:]).arguments,
            ["--session", "ses_abc123"]
        )
        XCTAssertEqual(
            registry.provider(for: .antigravity).launchPlan(goal: nil, resumeIntent: .resume("conv-xyz789"), settings: AppSettings(), baseEnvironment: [:]).arguments,
            ["--conversation", "conv-xyz789"]
        )
    }

    func testLaunchPlanAppendsGoalPromptPerAgent() {
        let registry = AgentProviderRegistry()
        let cases: [(AgentKind, String, String?, AgentEffort?, [String])] = [
            (.claudeCode, "Investigate crash in renderer", "sonnet", .high, [
                "--model", "sonnet", "--effort", "high", "--session-id", "uuid-1234", "Investigate crash in renderer",
            ]),
            (.codexCLI, "Write unit tests for parser", "gpt-5.5", .xhigh, [
                "--model", "gpt-5.5", "--config", "model_reasoning_effort=\"xhigh\"", "Write unit tests for parser",
            ]),
            (.openCode, "Refactor database migrations", "opencode/deepseek-v4-flash-free", nil, [
                "--model", "opencode/deepseek-v4-flash-free", "--prompt", "Refactor database migrations",
            ]),
            (.antigravity, "Fix layout bug in sidebar", "gemini-3.7-flash-high", .medium, [
                "--model", "gemini-3.7-flash-high", "--prompt-interactive", "Fix layout bug in sidebar",
            ]),
        ]
        for entry in cases {
            let resume: ResumeIntent = entry.0 == .claudeCode ? .freshWithAssignedIdentity("uuid-1234") : .none
            let plan = registry.provider(for: entry.0).launchPlan(
                goal: entry.1,
                model: entry.2,
                effort: entry.3,
                resumeIntent: resume,
                settings: AppSettings(),
                baseEnvironment: [:]
            )
            XCTAssertEqual(plan.arguments, entry.4, "\(entry.0)")
            XCTAssertNil(plan.initialInput, "\(entry.0)")
        }
    }

    func testLaunchPlanPlanModeFlagPerAgent() {
        let registry = AgentProviderRegistry()
        let goal = "Refactor database migrations"

        XCTAssertEqual(
            registry.provider(for: .openCode).launchPlan(
                goal: goal, model: "opencode/deepseek-v4-flash-free", mode: .plan, resumeIntent: .none,
                settings: AppSettings(), baseEnvironment: [:]
            ).arguments,
            ["--model", "opencode/deepseek-v4-flash-free", "--agent", "plan", "--prompt", goal]
        )
        XCTAssertEqual(
            registry.provider(for: .claudeCode).launchPlan(
                goal: goal, model: "sonnet", mode: .plan, resumeIntent: .none,
                settings: AppSettings(), baseEnvironment: [:]
            ).arguments,
            ["--model", "sonnet", "--permission-mode", "plan", goal]
        )
        XCTAssertEqual(
            registry.provider(for: .antigravity).launchPlan(
                goal: goal, model: "gemini-3.7-flash-high", mode: .plan, resumeIntent: .none,
                settings: AppSettings(), baseEnvironment: [:]
            ).arguments,
            ["--model", "gemini-3.7-flash-high", "--mode", "plan", "--prompt-interactive", goal]
        )
    }

    func testClaudeLaunchPlanKeepsPlanModeOnFirstLaunchWithAssignedIdentity() {
        let provider = AgentProviderRegistry().provider(for: .claudeCode)
        let id = UUID().uuidString
        let plan = provider.launchPlan(
            goal: "Refactor database migrations",
            model: "sonnet",
            mode: .plan,
            resumeIntent: .freshWithAssignedIdentity(id),
            settings: AppSettings(),
            baseEnvironment: [:]
        )

        XCTAssertEqual(plan.arguments, [
            "--model", "sonnet",
            "--permission-mode", "plan",
            "--session-id", id,
            "Refactor database migrations"
        ])
    }

    /// `--permission-mode` is a startup flag, so passing it alongside `--resume`
    /// would override the mode the conversation actually ended in and drop the
    /// session back into planning on every relaunch.
    func testClaudeLaunchPlanDropsPlanModeWhenResuming() {
        let provider = AgentProviderRegistry().provider(for: .claudeCode)
        let id = UUID().uuidString
        let plan = provider.launchPlan(
            goal: "Refactor database migrations",
            model: "sonnet",
            mode: .plan,
            resumeIntent: .resume(id),
            settings: AppSettings(),
            baseEnvironment: [:]
        )

        XCTAssertEqual(plan.arguments, ["--model", "sonnet", "--resume", id])
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

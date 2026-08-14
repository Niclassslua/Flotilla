import XCTest
import SessionKit
import AgentKit
import SettingsKit

final class AgentProviderTests: XCTestCase {
    func testRegistryMapsEveryAgentToItsExpectedExecutable() {
        let registry = AgentProviderRegistry()

        XCTAssertEqual(registry.provider(for: .claudeCode).binaryName, "claude")
        XCTAssertEqual(registry.provider(for: .codexCLI).binaryName, "codex")
        XCTAssertEqual(registry.provider(for: .geminiCLI).binaryName, "gemini")
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
        XCTAssertEqual(plan.initialInput, Data("Repair the build\n".utf8))
        XCTAssertEqual(plan.environment["TERM"], "xterm-256color")
        XCTAssertEqual(plan.environment["COLORTERM"], "truecolor")
        XCTAssertTrue(plan.environment["PATH"]?.contains("/opt/homebrew/bin") == true)
        XCTAssertTrue(plan.environment["PATH"]?.contains("/.local/bin") == true)
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
        XCTAssertNil(plan.environment["GEMINI_API_KEY"])
        XCTAssertNil(plan.initialInput)
    }
}

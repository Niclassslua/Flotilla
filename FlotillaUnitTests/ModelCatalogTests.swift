import XCTest
import SessionKit
import AgentKit
import ProcessKit

private struct FixedLocator: ExecutableLocating {
    let url: URL?
    func locate(_ name: String) -> URL? { url }
}

private struct MockRunnerError: Error, Sendable {}

private struct MockCommandRunner: CommandRunning {
    enum Outcome: Sendable {
        case success(CommandResult)
        case failure
    }

    let outcome: Outcome

    func run(_ arguments: [String], executable: URL, workingDirectory: URL) async throws -> CommandResult {
        switch outcome {
        case .success(let result): return result
        case .failure: throw MockRunnerError()
        }
    }
}

/// Claude Code needs two different queries answered (`/model` and `/effort`),
/// so responses are keyed by the slash command in the arguments.
private struct ScriptedCommandRunner: CommandRunning {
    let responses: [String: String]

    func run(_ arguments: [String], executable: URL, workingDirectory: URL) async throws -> CommandResult {
        guard let key = arguments.last, let stdout = responses[key] else { throw MockRunnerError() }
        return CommandResult(exitCode: 0, stdout: stdout, stderr: "")
    }
}

final class ModelCatalogTests: XCTestCase {
    func testFetchModelsParsesClaudeAvailableListDroppingLongContextAndDefault() async {
        let stdout = """
        Current model: Sonnet 5 (effort: high)
        Usage: /model <name>. Available: sonnet, opus, haiku, fable, best, sonnet[1m], opus[1m], fable[1m], opusplan, default, or a full model ID.
        """
        let fetcher = ModelCatalogFetcher(
            locator: FixedLocator(url: URL(fileURLWithPath: "/usr/local/bin/claude")),
            runner: MockCommandRunner(outcome: .success(CommandResult(exitCode: 0, stdout: stdout, stderr: "")))
        )

        let models = await fetcher.fetchModels(for: .claudeCode)

        XCTAssertEqual(models, ["sonnet", "opus", "haiku", "fable", "best", "opusplan"])
    }

    func testFetchModelsParsesCodexCatalogFilteringHiddenAndSortingByPriority() async {
        let json = """
        {"models":[
          {"slug":"gpt-5.4","visibility":"list","priority":16},
          {"slug":"hidden-model","visibility":"hide","priority":0},
          {"slug":"gpt-5.6-sol","visibility":"list","priority":1}
        ]}
        """
        let fetcher = ModelCatalogFetcher(
            locator: FixedLocator(url: URL(fileURLWithPath: "/usr/local/bin/codex")),
            runner: MockCommandRunner(outcome: .success(CommandResult(exitCode: 0, stdout: json, stderr: "")))
        )

        let models = await fetcher.fetchModels(for: .codexCLI)

        XCTAssertEqual(models, ["gpt-5.6-sol", "gpt-5.4"])
    }

    func testFetchModelsFallsBackOnAllFailureModes() async {
        // Mode 1: CLI binary not found
        let notFoundFetcher = ModelCatalogFetcher(
            locator: FixedLocator(url: nil),
            runner: MockCommandRunner(outcome: .failure)
        )
        let fallbackNotFound = await notFoundFetcher.fetchModels(for: .claudeCode)
        XCTAssertEqual(fallbackNotFound, ModelCatalog.staticFallback(for: .claudeCode))

        // Mode 2: Command runner throws
        let throwingFetcher = ModelCatalogFetcher(
            locator: FixedLocator(url: URL(fileURLWithPath: "/usr/local/bin/claude")),
            runner: MockCommandRunner(outcome: .failure)
        )
        let fallbackThrowing = await throwingFetcher.fetchModels(for: .claudeCode)
        XCTAssertEqual(fallbackThrowing, ModelCatalog.staticFallback(for: .claudeCode))

        // Mode 3: Non-zero exit code
        let nonZeroFetcher = ModelCatalogFetcher(
            locator: FixedLocator(url: URL(fileURLWithPath: "/usr/local/bin/codex")),
            runner: MockCommandRunner(outcome: .success(CommandResult(exitCode: 1, stdout: "", stderr: "boom")))
        )
        let fallbackNonZero = await nonZeroFetcher.fetchModels(for: .codexCLI)
        XCTAssertEqual(fallbackNonZero, ModelCatalog.staticFallback(for: .codexCLI))
    }

    // MARK: - Per-agent / per-model effort levels

    func testCodexProfilesCarryPerModelReasoningLevelsAndDefault() async {
        let json = """
        {"models":[
          {"slug":"gpt-5.6-sol","visibility":"list","priority":1,"default_reasoning_level":"low",
           "supported_reasoning_levels":[
             {"effort":"low","description":"Fast responses with lighter reasoning"},
             {"effort":"medium","description":"Balances speed and reasoning depth for everyday tasks"},
             {"effort":"ultra","description":"Maximum reasoning with automatic task delegation"},
             {"effort":"sideways","description":"A level this build has never heard of"}
           ]},
          {"slug":"gpt-5.4","visibility":"list","priority":16,"default_reasoning_level":"medium",
           "supported_reasoning_levels":[
             {"effort":"low","description":"Fast"},
             {"effort":"medium","description":"Balanced"},
             {"effort":"xhigh","description":"Extra high reasoning depth for complex problems"}
           ]}
        ]}
        """
        let fetcher = ModelCatalogFetcher(
            locator: FixedLocator(url: URL(fileURLWithPath: "/usr/local/bin/codex")),
            runner: MockCommandRunner(outcome: .success(CommandResult(exitCode: 0, stdout: json, stderr: "")))
        )

        let profiles = await fetcher.fetchProfiles(for: .codexCLI)

        XCTAssertEqual(profiles.map(\.slug), ["gpt-5.6-sol", "gpt-5.4"])
        // The unknown "sideways" level is dropped rather than guessed at.
        XCTAssertEqual(profiles[0].effortOptions.map(\.level), [.low, .medium, .ultra])
        XCTAssertEqual(profiles[0].defaultEffort, .low)
        XCTAssertEqual(profiles[1].effortOptions.map(\.level), [.low, .medium, .xhigh])
        XCTAssertEqual(profiles[1].defaultEffort, .medium)
        // Codex's own description is preferred over Flotilla's fallback copy.
        XCTAssertEqual(profiles[1].effortOptions.last?.summary, "Extra high reasoning depth for complex problems")
        XCTAssertEqual(profiles[1].effortOptions.last?.label, "Extra High")
    }

    func testClaudeProfilesReadEffortLevelsFromTheCLIDroppingAuto() async {
        let runner = ScriptedCommandRunner(responses: [
            "/model": "Usage: /model <name>. Available: sonnet, opus, default, or a full model ID.",
            "/effort": "Usage: /effort <low|medium|high|xhigh|max|auto>",
        ])
        let fetcher = ModelCatalogFetcher(
            locator: FixedLocator(url: URL(fileURLWithPath: "/usr/local/bin/claude")),
            runner: runner
        )

        let profiles = await fetcher.fetchProfiles(for: .claudeCode)

        XCTAssertEqual(profiles.map(\.slug), ["sonnet", "opus"])
        // `auto` is a slash-command-only option; `--effort auto` is rejected.
        for profile in profiles {
            XCTAssertEqual(profile.effortOptions.map(\.level), [.low, .medium, .high, .xhigh, .max])
            XCTAssertNil(profile.defaultEffort)
        }
    }

    func testClaudeEffortParsingIgnoresUnknownLevelsAndOrdersByDepth() async {
        let fetcher = ModelCatalogFetcher(
            locator: FixedLocator(url: URL(fileURLWithPath: "/usr/local/bin/claude")),
            runner: ScriptedCommandRunner(responses: [
                "/model": "Usage: /model <name>. Available: opus, or a full model ID.",
                "/effort": "Usage: /effort <max|low|turbo|medium>",
            ])
        )

        let profiles = await fetcher.fetchProfiles(for: .claudeCode)

        XCTAssertEqual(profiles.first?.effortOptions.map(\.level), [.low, .medium, .max])
    }

    func testClaudeFallsBackToTheStaticLevelTableWhenTheEffortQueryFails() async {
        let fetcher = ModelCatalogFetcher(
            locator: FixedLocator(url: URL(fileURLWithPath: "/usr/local/bin/claude")),
            runner: ScriptedCommandRunner(responses: [
                "/model": "Usage: /model <name>. Available: opus, or a full model ID."
            ])
        )

        let profiles = await fetcher.fetchProfiles(for: .claudeCode)

        XCTAssertEqual(profiles.map(\.slug), ["opus"])
        XCTAssertEqual(
            profiles.first?.effortOptions.map(\.level),
            AgentEffortCatalog.supportedLevels(for: .claudeCode)
        )
    }

    func testEffortOptionsForAnUnpinnedModelOfferOnlyWhatEveryModelAccepts() {
        let profiles = [
            AgentModelProfile(slug: "deep", effortOptions: [
                AgentEffortOption(level: .low, label: "Low", summary: "fast"),
                AgentEffortOption(level: .high, label: "High", summary: "deep"),
                AgentEffortOption(level: .ultra, label: "Ultra", summary: "deepest", isModelDefault: true),
            ]),
            AgentModelProfile(slug: "shallow", effortOptions: [
                AgentEffortOption(level: .low, label: "Low", summary: "fast"),
                AgentEffortOption(level: .high, label: "High", summary: "deep"),
            ]),
        ]

        let pinned = AgentEffortCatalog.options(for: .codexCLI, model: "deep", profiles: profiles)
        let unpinned = AgentEffortCatalog.options(for: .codexCLI, model: "", profiles: profiles)
        let custom = AgentEffortCatalog.options(for: .codexCLI, model: "some-private-slug", profiles: profiles)

        XCTAssertEqual(pinned.map(\.level), [.low, .high, .ultra])
        XCTAssertEqual(pinned.last?.isModelDefault, true)
        // `ultra` is dropped: picking it while the CLI runs "shallow" would
        // fail the run outright.
        XCTAssertEqual(unpinned.map(\.level), [.low, .high])
        XCTAssertEqual(custom.map(\.level), [.low, .high])
        XCTAssertFalse(unpinned.contains { $0.isModelDefault })
    }

    func testEffortOptionsFallBackToTheAgentTableWithNoCatalogAtAll() {
        let options = AgentEffortCatalog.options(for: .claudeCode, model: "opus", profiles: [])

        XCTAssertEqual(options.map(\.level), AgentEffortCatalog.supportedLevels(for: .claudeCode))
    }

    func testOpenCodeOffersNoEffortLevels() {
        XCTAssertTrue(AgentEffortCatalog.supportedLevels(for: .openCode).isEmpty)
        XCTAssertTrue(AgentEffortCatalog.options(for: .openCode, model: "opencode/kimi-k3").isEmpty)
        XCTAssertFalse(AgentKind.openCode.supportsEffortSelection)
    }

    func testClaudeCodeRejectsCodexOnlyLevels() {
        XCTAssertFalse(AgentEffortCatalog.supports(.ultra, agent: .claudeCode))
        XCTAssertFalse(AgentEffortCatalog.supports(.minimal, agent: .claudeCode))
        XCTAssertTrue(AgentEffortCatalog.supports(.max, agent: .claudeCode))
        XCTAssertTrue(AgentEffortCatalog.supports(.ultra, agent: .codexCLI))
    }

    func testClampSnapsToTheNearestSupportedLevel() {
        let options = AgentEffortCatalog.staticOptions(for: .claudeCode)

        XCTAssertEqual(AgentEffortCatalog.clamp(.ultra, to: options), .max)
        XCTAssertEqual(AgentEffortCatalog.clamp(.high, to: options), .high)
        XCTAssertNil(AgentEffortCatalog.clamp(.high, to: []))
    }

    func testStaticFallbackProfilesNarrowKnownCodexModels() {
        let profiles = ModelCatalog.staticFallbackProfiles(for: .codexCLI)

        let sol = profiles.first { $0.slug == "gpt-5.6-sol" }
        let legacy = profiles.first { $0.slug == "gpt-5.4" }
        XCTAssertEqual(sol?.effortOptions.map(\.level), [.low, .medium, .high, .xhigh, .max, .ultra])
        XCTAssertEqual(legacy?.effortOptions.map(\.level), [.low, .medium, .high, .xhigh])
    }

    func testOpenCodeAlwaysUsesStaticFallbackSinceThereIsNoEnumerationCommand() async {
        let fetcher = ModelCatalogFetcher(
            locator: FixedLocator(url: URL(fileURLWithPath: "/usr/local/bin/opencode")),
            runner: MockCommandRunner(outcome: .failure)
        )

        let models = await fetcher.fetchModels(for: .openCode)

        XCTAssertEqual(models, ModelCatalog.staticFallback(for: .openCode))
    }

    func testAntigravitySupportsLowMediumHighEffortLevels() {
        XCTAssertEqual(AgentEffortCatalog.supportedLevels(for: .antigravity), [.low, .medium, .high])
        XCTAssertTrue(AgentKind.antigravity.supportsEffortSelection)
        XCTAssertTrue(AgentEffortCatalog.supports(.low, agent: .antigravity))
        XCTAssertTrue(AgentEffortCatalog.supports(.medium, agent: .antigravity))
        XCTAssertTrue(AgentEffortCatalog.supports(.high, agent: .antigravity))
        XCTAssertFalse(AgentEffortCatalog.supports(.max, agent: .antigravity))
        XCTAssertFalse(AgentEffortCatalog.supports(.ultra, agent: .antigravity))
    }

    func testAntigravityStaticFallbackProfiles() {
        let profiles = ModelCatalog.staticFallbackProfiles(for: .antigravity)
        XCTAssertFalse(profiles.isEmpty)
        XCTAssertTrue(profiles.contains(where: { $0.slug == "gemini-3.7-flash-high" }))
        XCTAssertEqual(profiles.first(where: { $0.slug == "gemini-3.7-flash-high" })?.displayName, "Gemini 3.7 Flash (High)")
        XCTAssertEqual(ModelCatalog.staticFallback(for: .antigravity), profiles.map(\.slug))
    }

    func testAntigravityEffortParsingFromHelpOutput() {
        let helpOutput = """
        Usage of agy:
          --effort                        Reasoning effort for the current CLI session (low|medium|high)
          --model                         Model for the current CLI session
        """
        let levels = ModelCatalogFetcher.parseAntigravityEffortLevels(helpOutput)
        XCTAssertEqual(levels, [.low, .medium, .high])
    }

    func testAntigravityModelParsing() {
        let output = """
          agy models
          gemini-3.7-flash-high     Gemini 3.7 Flash (High)
          gemini-3.7-flash-medium   Gemini 3.7 Flash (Medium)
          gemini-3.7-flash-low      Gemini 3.7 Flash (Low)
          gemini-3.6-flash-high     Gemini 3.6 Flash (High)
          claude-sonnet-4-6         Claude Sonnet 4.6 (Thinking)
          claude-opus-4-6-thinking  Claude Opus 4.6 (Thinking)
          gpt-oss-120b-medium       GPT-OSS 120B (Medium)
        """
        let entries = ModelCatalogFetcher.parseAntigravityModelEntries(output)
        XCTAssertEqual(entries.count, 7)
        XCTAssertEqual(entries[0].slug, "gemini-3.7-flash-high")
        XCTAssertEqual(entries[0].displayName, "Gemini 3.7 Flash (High)")
        XCTAssertEqual(entries[4].slug, "claude-sonnet-4-6")
        XCTAssertEqual(entries[4].displayName, "Claude Sonnet 4.6 (Thinking)")

        let slugs = ModelCatalogFetcher.parseAntigravityModelList(output)
        XCTAssertEqual(slugs, [
            "gemini-3.7-flash-high",
            "gemini-3.7-flash-medium",
            "gemini-3.7-flash-low",
            "gemini-3.6-flash-high",
            "claude-sonnet-4-6",
            "claude-opus-4-6-thinking",
            "gpt-oss-120b-medium"
        ])
    }
}

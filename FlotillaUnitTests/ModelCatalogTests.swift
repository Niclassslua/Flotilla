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

final class ModelCatalogTests: XCTestCase {
    func testFetchModelsReturnsStaticFallbackWhenCLINotFound() async {
        let fetcher = ModelCatalogFetcher(
            locator: FixedLocator(url: nil),
            runner: MockCommandRunner(outcome: .failure)
        )

        let models = await fetcher.fetchModels(for: .claudeCode)

        XCTAssertEqual(models, ModelCatalog.staticFallback(for: .claudeCode))
    }

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

    func testFetchModelsFallsBackWhenCommandFails() async {
        let fetcher = ModelCatalogFetcher(
            locator: FixedLocator(url: URL(fileURLWithPath: "/usr/local/bin/claude")),
            runner: MockCommandRunner(outcome: .failure)
        )

        let models = await fetcher.fetchModels(for: .claudeCode)

        XCTAssertEqual(models, ModelCatalog.staticFallback(for: .claudeCode))
    }

    func testFetchModelsFallsBackOnNonZeroExitCode() async {
        let fetcher = ModelCatalogFetcher(
            locator: FixedLocator(url: URL(fileURLWithPath: "/usr/local/bin/codex")),
            runner: MockCommandRunner(outcome: .success(CommandResult(exitCode: 1, stdout: "", stderr: "boom")))
        )

        let models = await fetcher.fetchModels(for: .codexCLI)

        XCTAssertEqual(models, ModelCatalog.staticFallback(for: .codexCLI))
    }

    func testOpenCodeAlwaysUsesStaticFallbackSinceThereIsNoEnumerationCommand() async {
        let fetcher = ModelCatalogFetcher(
            locator: FixedLocator(url: URL(fileURLWithPath: "/usr/local/bin/opencode")),
            runner: MockCommandRunner(outcome: .failure)
        )

        let models = await fetcher.fetchModels(for: .openCode)

        XCTAssertEqual(models, ModelCatalog.staticFallback(for: .openCode))
    }
}

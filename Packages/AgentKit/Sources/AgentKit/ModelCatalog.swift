import Foundation
import SessionKit
import ProcessKit
import SettingsKit

/// Live-queries each agent's installed CLI for its current model list,
/// instead of hardcoding one that inevitably goes stale. Resolution always
/// uses `PATH` (not any configured `AgentPathOverrides` binary) — model
/// discovery is a best-effort convenience, not the actual launch path.
public struct ModelCatalogFetcher: Sendable {
    private let locator: ExecutableLocating
    private let runner: CommandRunning
    private let timeoutSeconds: Double

    public init(
        locator: ExecutableLocating = PATHExecutableLocator(),
        runner: CommandRunning = ProcessCommandRunner(),
        timeoutSeconds: Double = 6
    ) {
        self.locator = locator
        self.runner = runner
        self.timeoutSeconds = timeoutSeconds
    }

    /// Falls back to `ModelCatalog.staticFallback(for:openCodeSubscription:)`
    /// when the CLI isn't installed, the query fails or times out, or no
    /// enumeration is available. `openCodeSubscription` only affects
    /// OpenCode: with a plan configured, its provider's models are
    /// enumerated live via `opencode models <provider>`.
    public func fetchModels(
        for agent: AgentKind,
        openCodeSubscription: OpenCodeSubscription = .none
    ) async -> [String] {
        guard let executable = locator.locate(binaryName(for: agent)) else {
            return ModelCatalog.staticFallback(for: agent, openCodeSubscription: openCodeSubscription)
        }

        let models: [String]?
        do {
            models = try await withTimeout(seconds: timeoutSeconds) {
                switch agent {
                case .claudeCode: try await self.fetchClaudeModels(executable: executable)
                case .codexCLI: try await self.fetchCodexModels(executable: executable)
                case .openCode: try await self.fetchOpenCodeModels(executable: executable, subscription: openCodeSubscription)
                }
            }
        } catch {
            models = nil
        }

        guard let models, !models.isEmpty else {
            return ModelCatalog.staticFallback(for: agent, openCodeSubscription: openCodeSubscription)
        }
        return models
    }

    private func binaryName(for agent: AgentKind) -> String {
        switch agent {
        case .claudeCode: "claude"
        case .codexCLI: "codex"
        case .openCode: "opencode"
        }
    }

    /// `opencode models <provider>` prints the subscription's models, one
    /// per line (e.g. "opencode-go/kimi-k3"). Without a configured
    /// subscription there is nothing to scope the query to, so the static
    /// shortlist stays in charge.
    private func fetchOpenCodeModels(executable: URL, subscription: OpenCodeSubscription) async throws -> [String]? {
        guard let provider = subscription.providerID else { return nil }
        let result = try await runner.run(
            ["models", provider],
            executable: executable,
            workingDirectory: FileManager.default.temporaryDirectory
        )
        guard result.exitCode == 0 else { return nil }
        let models = Self.parseOpenCodeModelList(result.stdout)
        return models.isEmpty ? nil : models
    }

    static func parseOpenCodeModelList(_ output: String) -> [String] {
        output
            .split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { $0.contains("/") && !$0.contains(" ") }
    }

    private func fetchClaudeModels(executable: URL) async throws -> [String]? {
        let result = try await runner.run(
            ["--print", "/model"],
            executable: executable,
            workingDirectory: FileManager.default.temporaryDirectory
        )
        guard result.exitCode == 0 else { return nil }
        return Self.parseClaudeModelList(result.stdout)
    }

    private func fetchCodexModels(executable: URL) async throws -> [String]? {
        let result = try await runner.run(
            ["debug", "models"],
            executable: executable,
            workingDirectory: FileManager.default.temporaryDirectory
        )
        guard result.exitCode == 0, let data = result.stdout.data(using: .utf8) else { return nil }
        let catalog = try JSONDecoder().decode(CodexModelCatalog.self, from: data)
        return catalog.models
            .filter { $0.visibility == "list" }
            .sorted { $0.priority < $1.priority }
            .map(\.slug)
    }

    /// `claude --print "/model"` (skips the workspace-trust dialog and any
    /// interactive UI because it's non-interactive/piped) prints e.g.:
    /// "Usage: /model <name>. Available: sonnet, opus, haiku, fable, best,
    /// sonnet[1m], opus[1m], fable[1m], opusplan, default, or a full model ID."
    /// The `[1m]` long-context variants and the "default"/"or a full model
    /// ID" prose are dropped — still reachable via the picker's "Custom…".
    static func parseClaudeModelList(_ output: String) -> [String] {
        guard let range = output.range(of: "Available: ") else { return [] }
        let tail = output[range.upperBound...]
        return tail
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && !$0.contains(" ") && $0 != "default" && !$0.contains("[1m]") }
    }

    private struct CodexModelCatalog: Decodable {
        let models: [CodexModelEntry]
    }

    private struct CodexModelEntry: Decodable {
        let slug: String
        let visibility: String
        let priority: Int
    }
}

private struct TimeoutError: Error {}

private func withTimeout<T: Sendable>(
    seconds: Double,
    operation: @escaping @Sendable () async throws -> T
) async throws -> T {
    try await withThrowingTaskGroup(of: T.self) { group in
        group.addTask { try await operation() }
        group.addTask {
            try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            throw TimeoutError()
        }
        defer { group.cancelAll() }
        return try await group.next()!
    }
}

/// Small static shortlist used when live discovery isn't possible: the CLI
/// isn't installed, the query failed/timed out, or — as with OpenCode,
/// which has no model-enumeration command — was never attempted.
public enum ModelCatalog {
    public static func staticFallback(for agent: AgentKind, openCodeSubscription: OpenCodeSubscription = .none) -> [String] {
        switch agent {
        case .claudeCode: ["sonnet", "opus", "haiku", "fable", "best", "opusplan"]
        case .codexCLI: ["gpt-5.6-sol", "gpt-5.6-terra", "gpt-5.6-luna", "gpt-5.5", "gpt-5.4", "gpt-5.4-mini"]
        case .openCode: [
            // opencode/* — built-in free models
            "opencode/nemotron-3-ultra-free",
            "opencode/nemotron-3.5-lightning-free",
            "opencode/big-pickle",
            "opencode/deepseek-v4-flash-free",
            "opencode/hy3-free",
            "opencode/laguna-s-2.1-free",
            "opencode/mimo-v2.5-free",
            // opencode-go/* — additional free models
            "opencode-go/deepseek-v4-flash",
            "opencode-go/deepseek-v4-pro",
            "opencode-go/glm-5.1",
            "opencode-go/glm-5.2",
            "opencode-go/glm-5.3",
            "opencode-go/gpt-5.6-luna",
            "opencode-go/grok-4.5",
            "opencode-go/hy3",
            "opencode-go/kimi-k2.6",
            "opencode-go/kimi-k2.7-code",
            "opencode-go/kimi-k3",
            "opencode-go/mimo-v2.5",
            "opencode-go/mimo-v2.5-pro",
            "opencode-go/minimax-m2.7",
            "opencode-go/minimax-m3",
            "opencode-go/qwen3.6-plus",
            "opencode-go/qwen3.7-max",
            "opencode-go/qwen3.7-plus",
            "opencode-go/qwen3.8-max",
            // openrouter/~ — latest aliases for popular models
            "openrouter/~anthropic/claude-sonnet-latest",
            "openrouter/~anthropic/claude-opus-latest",
            "openrouter/~anthropic/claude-haiku-latest",
            "openrouter/~openai/gpt-latest",
            "openrouter/~openai/gpt-mini-latest",
            "openrouter/~x-ai/grok-latest",
            "openrouter/~deepseek/deepseek-v4-flash-latest",
            "openrouter/~moonshotai/kimi-latest",
            // openrouter/ — popular specific models
            "openrouter/anthropic/claude-3.5-sonnet",
            "openrouter/anthropic/claude-3.5-haiku",
            "openrouter/anthropic/claude-3-opus",
            "openrouter/openai/gpt-4o",
            "openrouter/openai/gpt-4o-mini",
            "openrouter/openai/o1",
            "openrouter/openai/o3-mini",
            "openrouter/x-ai/grok-4.5",
            "openrouter/meta-llama/llama-3.3-70b-instruct",
            "openrouter/mistralai/mistral-large",
            "openrouter/deepseek/deepseek-chat",
            "openrouter/deepseek/deepseek-r1",
            "openrouter/qwen/qwen-2.5-coder-32b-instruct",
            "openrouter/qwen/qwen3-coder",
            "openrouter/nvidia/nemotron-3-ultra-550b-a55b",
            "openrouter/anthropic/claude-opus-4",
            "openrouter/anthropic/claude-sonnet-4",
        ]
        }
    }
}

/// Per-agent in-memory cache so repeatedly opening a session-creation
/// surface doesn't re-shell-out on every appearance. Lives for the process
/// lifetime; a newly installed CLI version is picked up on next launch.
public actor ModelCatalogCache {
    public static let shared = ModelCatalogCache()

    private var cache: [AgentKind: [String]] = [:]
    private let fetcher: ModelCatalogFetcher

    public init(fetcher: ModelCatalogFetcher = ModelCatalogFetcher()) {
        self.fetcher = fetcher
    }

    public func models(for agent: AgentKind, openCodeSubscription: OpenCodeSubscription = .none) async -> [String] {
        if let cached = cache[agent] {
            return cached
        }
        let models = await fetcher.fetchModels(for: agent, openCodeSubscription: openCodeSubscription)
        cache[agent] = models
        return models
    }
}

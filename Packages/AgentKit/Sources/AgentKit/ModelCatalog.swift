import Foundation
import SessionKit
import ProcessKit
import SettingsKit

/// One model as the agent's CLI describes it, including which reasoning-effort
/// levels it accepts. Codex narrows the levels per model (and publishes a
/// per-level description plus its own default); Claude Code applies the same
/// five levels to every model.
public struct AgentModelProfile: Sendable, Equatable, Identifiable {
    public let slug: String
    public let displayName: String?
    public let effortOptions: [AgentEffortOption]

    public var id: String { slug }

    public init(slug: String, displayName: String? = nil, effortOptions: [AgentEffortOption]) {
        self.slug = slug
        self.displayName = displayName
        self.effortOptions = effortOptions
    }

    public var defaultEffort: AgentEffort? {
        effortOptions.first(where: \.isModelDefault)?.level
    }
}

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
        await fetchProfiles(for: agent, openCodeSubscription: openCodeSubscription).map(\.slug)
    }

    /// Same query as `fetchModels`, keeping the per-model reasoning-effort
    /// levels the CLI reports. Only Codex publishes them; Claude Code's five
    /// levels are attached from `AgentEffortCatalog`'s static table, and
    /// OpenCode's profiles carry none.
    public func fetchProfiles(
        for agent: AgentKind,
        openCodeSubscription: OpenCodeSubscription = .none
    ) async -> [AgentModelProfile] {
        guard let executable = locator.locate(binaryName(for: agent)) else {
            return ModelCatalog.staticFallbackProfiles(for: agent, openCodeSubscription: openCodeSubscription)
        }

        let profiles: [AgentModelProfile]?
        do {
            profiles = try await withTimeout(seconds: timeoutSeconds) {
                switch agent {
                case .claudeCode:
                    try await self.fetchClaudeProfiles(executable: executable)
                case .codexCLI:
                    try await self.fetchCodexProfiles(executable: executable)
                case .openCode:
                    try await self.fetchOpenCodeModels(executable: executable, subscription: openCodeSubscription)
                        .map { Self.profiles(forSlugs: $0, agent: .openCode) }
                }
            }
        } catch {
            profiles = nil
        }

        guard let profiles, !profiles.isEmpty else {
            return ModelCatalog.staticFallbackProfiles(for: agent, openCodeSubscription: openCodeSubscription)
        }
        return profiles
    }

    static func profiles(forSlugs slugs: [String], agent: AgentKind) -> [AgentModelProfile] {
        let options = AgentEffortCatalog.staticOptions(for: agent)
        return slugs.map { AgentModelProfile(slug: $0, effortOptions: options) }
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

    /// Claude Code applies `--effort` uniformly to every model, so one query
    /// for the level list covers the whole catalog. The two queries run
    /// concurrently because both shell out to the same CLI and neither
    /// depends on the other.
    private func fetchClaudeProfiles(executable: URL) async throws -> [AgentModelProfile]? {
        async let modelsTask = fetchClaudeModels(executable: executable)
        async let levelsTask = fetchClaudeEffortLevels(executable: executable)
        guard let models = try await modelsTask, !models.isEmpty else {
            _ = try? await levelsTask
            return nil
        }
        let levels = (try? await levelsTask) ?? nil

        let options: [AgentEffortOption] = levels.map { levels in
            levels.map { level in
                AgentEffortOption(
                    level: level,
                    label: AgentEffortCatalog.label(for: level, agent: .claudeCode),
                    summary: AgentEffortCatalog.summary(for: level, agent: .claudeCode)
                )
            }
        } ?? AgentEffortCatalog.staticOptions(for: .claudeCode)

        return models.map { AgentModelProfile(slug: $0, effortOptions: options) }
    }

    private func fetchClaudeEffortLevels(executable: URL) async throws -> [AgentEffort]? {
        let result = try await runner.run(
            ["--print", "/effort"],
            executable: executable,
            workingDirectory: FileManager.default.temporaryDirectory
        )
        guard result.exitCode == 0 else { return nil }
        let levels = Self.parseClaudeEffortLevels(result.stdout)
        return levels.isEmpty ? nil : levels
    }

    /// `claude --print "/effort"` prints its own usage line, e.g.
    /// "Usage: /effort <low|medium|high|xhigh|max|auto>". `auto` is dropped:
    /// it is a slash-command-only option, and `--effort auto` warns and falls
    /// back to the default. Unknown level names from a newer CLI are dropped
    /// too rather than guessed at.
    static func parseClaudeEffortLevels(_ output: String) -> [AgentEffort] {
        guard let open = output.firstIndex(of: "<"),
              let close = output[open...].firstIndex(of: ">") else { return [] }
        return output[output.index(after: open)..<close]
            .split(separator: "|")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .compactMap(AgentEffort.init(rawValue:))
            .sorted { $0.rank < $1.rank }
    }

    private func fetchCodexProfiles(executable: URL) async throws -> [AgentModelProfile]? {
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
            .map(Self.profile(fromCodexEntry:))
    }

    /// Codex's catalog is the authority on which levels a model takes, so
    /// unknown level strings from a newer CLI are dropped rather than guessed
    /// at — the picker then simply doesn't offer them.
    static func profile(fromCodexEntry entry: CodexModelEntry) -> AgentModelProfile {
        let levels = entry.supportedReasoningLevels ?? []
        let options: [AgentEffortOption] = levels.compactMap { level in
            guard let effort = AgentEffort(rawValue: level.effort) else { return nil }
            return AgentEffortOption(
                level: effort,
                label: AgentEffortCatalog.label(for: effort, agent: .codexCLI),
                summary: level.description ?? AgentEffortCatalog.summary(for: effort, agent: .codexCLI),
                isModelDefault: effort.rawValue == entry.defaultReasoningLevel
            )
        }
        return AgentModelProfile(
            slug: entry.slug,
            displayName: entry.displayName,
            effortOptions: options.isEmpty ? AgentEffortCatalog.staticOptions(for: .codexCLI) : options
        )
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

    struct CodexModelCatalog: Decodable {
        let models: [CodexModelEntry]
    }

    struct CodexModelEntry: Decodable {
        let slug: String
        let visibility: String
        let priority: Int
        let displayName: String?
        let defaultReasoningLevel: String?
        let supportedReasoningLevels: [CodexReasoningLevel]?

        enum CodingKeys: String, CodingKey {
            case slug
            case visibility
            case priority
            case displayName = "display_name"
            case defaultReasoningLevel = "default_reasoning_level"
            case supportedReasoningLevels = "supported_reasoning_levels"
        }
    }

    struct CodexReasoningLevel: Decodable {
        let effort: String
        let description: String?
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
    /// `staticFallback` plus the reasoning-effort levels each of those models
    /// took at the time of writing. Codex's real per-model support comes from
    /// `codex debug models`; this table only covers the case where that query
    /// isn't possible, and is deliberately conservative — a model missing here
    /// gets the agent's full level set rather than a guessed-narrow one.
    public static func staticFallbackProfiles(
        for agent: AgentKind,
        openCodeSubscription: OpenCodeSubscription = .none
    ) -> [AgentModelProfile] {
        let slugs = staticFallback(for: agent, openCodeSubscription: openCodeSubscription)
        return slugs.map { slug in
            AgentModelProfile(slug: slug, effortOptions: fallbackEffortOptions(for: agent, slug: slug))
        }
    }

    private static func fallbackEffortOptions(for agent: AgentKind, slug: String) -> [AgentEffortOption] {
        let all = AgentEffortCatalog.staticOptions(for: agent)
        guard agent == .codexCLI else { return all }
        // `minimal` is in Codex's config schema but no shipped model has ever
        // listed it, so it stays out of the offline set; the live catalog will
        // surface it if that ever changes.
        let ceiling = codexFallbackCeiling[slug] ?? .ultra
        return all.filter { $0.level.rank >= AgentEffort.low.rank && $0.level.rank <= ceiling.rank }
    }

    /// Deepest level each known Codex model accepted as of Codex CLI 0.147.
    /// Newer models are absent on purpose — they fall through to the full set.
    private static let codexFallbackCeiling: [String: AgentEffort] = [
        "gpt-5.6-sol": .ultra,
        "gpt-5.6-terra": .ultra,
        "gpt-5.6-luna": .max,
        "gpt-5.5": .xhigh,
        "gpt-5.4": .xhigh,
        "gpt-5.4-mini": .xhigh,
    ]

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

    private var cache: [AgentKind: [AgentModelProfile]] = [:]
    private let fetcher: ModelCatalogFetcher

    public init(fetcher: ModelCatalogFetcher = ModelCatalogFetcher()) {
        self.fetcher = fetcher
    }

    public func models(for agent: AgentKind, openCodeSubscription: OpenCodeSubscription = .none) async -> [String] {
        await profiles(for: agent, openCodeSubscription: openCodeSubscription).map(\.slug)
    }

    public func profiles(for agent: AgentKind, openCodeSubscription: OpenCodeSubscription = .none) async -> [AgentModelProfile] {
        if let cached = cache[agent] {
            return cached
        }
        let profiles = await fetcher.fetchProfiles(for: agent, openCodeSubscription: openCodeSubscription)
        cache[agent] = profiles
        return profiles
    }
}

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
    public let description: String?
    public let effortOptions: [AgentEffortOption]

    public var id: String { slug }

    public init(slug: String, displayName: String? = nil, description: String? = nil, effortOptions: [AgentEffortOption]) {
        self.slug = slug
        self.displayName = displayName
        self.description = description
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
                    try await self.fetchOpenCodeProfiles(executable: executable, subscription: openCodeSubscription)
                case .antigravity:
                    try await self.fetchAntigravityProfiles(executable: executable)
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
        return slugs.map { slug in
            AgentModelProfile(slug: slug, displayName: ModelCatalog.displayName(for: slug, agent: agent), effortOptions: options)
        }
    }

    private func binaryName(for agent: AgentKind) -> String {
        AgentCatalog.descriptor(for: agent).binaryName
    }

    /// `opencode models <provider>` prints the subscription's models, one
    /// per line (e.g. "opencode-go/kimi-k3"). Without a configured
    /// subscription there is nothing to scope the query to, so the static
    /// shortlist stays in charge.
    ///
    /// `--verbose` additionally prints each model's own JSON metadata (real
    /// `name`, cost, limits, …) after its slug line, which is where the
    /// human-facing display name comes from — the plain listing is only a
    /// fallback for when that fails to parse.
    private func fetchOpenCodeProfiles(executable: URL, subscription: OpenCodeSubscription) async throws -> [AgentModelProfile]? {
        guard let provider = subscription.providerID else { return nil }

        if let verboseResult = try? await runner.run(
            ["models", provider, "--verbose"],
            executable: executable,
            workingDirectory: FileManager.default.temporaryDirectory
        ), verboseResult.exitCode == 0 {
            let profiles = Self.parseOpenCodeVerboseModelList(verboseResult.stdout)
            if !profiles.isEmpty { return profiles }
        }

        let result = try await runner.run(
            ["models", provider],
            executable: executable,
            workingDirectory: FileManager.default.temporaryDirectory
        )
        guard result.exitCode == 0 else { return nil }
        let models = Self.parseOpenCodeModelList(result.stdout)
        return models.isEmpty ? nil : Self.profiles(forSlugs: models, agent: .openCode)
    }

    static func parseOpenCodeModelList(_ output: String) -> [String] {
        output
            .split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { $0.contains("/") && !$0.contains(" ") }
    }

    /// Parses `opencode models <provider> --verbose`, which prints each
    /// model's slug on its own line followed by a pretty-printed JSON object
    /// describing it (`id`, `providerID`, `name`, …). The slug line is
    /// ignored — `id`/`providerID` from the JSON itself rebuild it — since
    /// only the JSON carries the real display `name`.
    public static func parseOpenCodeVerboseModelList(_ output: String) -> [AgentModelProfile] {
        let options = AgentEffortCatalog.staticOptions(for: .openCode)
        let characters = Array(output)
        var profiles: [AgentModelProfile] = []
        var searchStart = characters.startIndex

        while searchStart < characters.endIndex,
              let braceStart = characters[searchStart...].firstIndex(of: "{") {
            guard let braceEnd = jsonObjectEnd(in: characters, from: braceStart) else { break }
            let jsonString = String(characters[braceStart...braceEnd])
            if let data = jsonString.data(using: .utf8),
               let entry = try? JSONDecoder().decode(OpenCodeVerboseModelEntry.self, from: data) {
                let slug = entry.providerID.map { "\($0)/\(entry.id)" } ?? entry.id
                profiles.append(AgentModelProfile(slug: slug, displayName: entry.name, effortOptions: options))
            }
            searchStart = characters.index(after: braceEnd)
        }
        return profiles
    }

    /// Finds the index of the `}` that closes the JSON object opened at
    /// `start`, respecting string contents so a `{`/`}` inside a quoted
    /// value (or an escaped quote) isn't mistaken for structure.
    private static func jsonObjectEnd(in characters: [Character], from start: Int) -> Int? {
        var depth = 0
        var inString = false
        var isEscaped = false
        var index = start
        while index < characters.count {
            let character = characters[index]
            if inString {
                if isEscaped {
                    isEscaped = false
                } else if character == "\\" {
                    isEscaped = true
                } else if character == "\"" {
                    inString = false
                }
            } else if character == "\"" {
                inString = true
            } else if character == "{" {
                depth += 1
            } else if character == "}" {
                depth -= 1
                if depth == 0 { return index }
            }
            index += 1
        }
        return nil
    }

    struct OpenCodeVerboseModelEntry: Decodable {
        let id: String
        let providerID: String?
        let name: String?
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

        return models.map { slug in
            AgentModelProfile(
                slug: slug,
                displayName: ModelCatalog.claudeModelDisplayName(for: slug),
                description: ModelCatalog.claudeModelDescription(for: slug),
                effortOptions: options
            )
        }
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

    public struct AntigravityModelEntry: Equatable, Sendable {
        public let slug: String
        public let displayName: String?

        public init(slug: String, displayName: String? = nil) {
            self.slug = slug
            self.displayName = displayName
        }
    }

    func fetchAntigravityGroups(for agent: AgentKind) async -> [AntigravityModelGroup] {
        guard let executable = locator.locate(binaryName(for: agent)) else {
            return ModelCatalog.staticAntigravityGroups()
        }
        let entries: [AntigravityModelEntry]?
        do {
            entries = try await withTimeout(seconds: timeoutSeconds) {
                try await self.fetchAntigravityModelEntries(executable: executable)
            }
        } catch {
            entries = nil
        }
        guard let entries, !entries.isEmpty else {
            return ModelCatalog.staticAntigravityGroups()
        }
        return ModelCatalog.groupAntigravityModels(entries.map { ($0.slug, $0.displayName) })
    }

    private func fetchAntigravityProfiles(executable: URL) async throws -> [AgentModelProfile]? {
        async let modelsTask = fetchAntigravityModelEntries(executable: executable)
        async let levelsTask = fetchAntigravityEffortLevels(executable: executable)
        guard let models = try await modelsTask, !models.isEmpty else {
            _ = try? await levelsTask
            return nil
        }
        _ = (try? await levelsTask)

        let groups = ModelCatalog.groupAntigravityModels(models.map { ($0.slug, $0.displayName) })
        return models.map { model in
            let options = ModelCatalog.antigravityEffortOptions(for: model.slug, in: groups)
            return AgentModelProfile(slug: model.slug, displayName: model.displayName, effortOptions: options)
        }
    }

    private func fetchAntigravityModelEntries(executable: URL) async throws -> [AntigravityModelEntry]? {
        let result = try await runner.run(
            ["models"],
            executable: executable,
            workingDirectory: FileManager.default.temporaryDirectory
        )
        guard result.exitCode == 0 else { return nil }
        let models = Self.parseAntigravityModelEntries(result.stdout)
        return models.isEmpty ? nil : models
    }

    private func fetchAntigravityModels(executable: URL) async throws -> [String]? {
        try await fetchAntigravityModelEntries(executable: executable)?.map(\.slug)
    }

    public static func parseAntigravityModelEntries(_ output: String) -> [AntigravityModelEntry] {
        output
            .split(separator: "\n")
            .compactMap { rawLine in
                let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !line.isEmpty,
                      !line.lowercased().hasPrefix("usage"),
                      !line.lowercased().hasPrefix("available"),
                      !line.lowercased().hasPrefix("name"),
                      !line.hasPrefix("-"),
                      !line.hasPrefix("#"),
                      !line.lowercased().hasPrefix("agy models"),
                      !line.lowercased().hasPrefix("agy") else {
                    return nil
                }
                let components = line.split(whereSeparator: \.isWhitespace).map(String.init)
                guard let slug = components.first, !slug.isEmpty, !slug.hasPrefix("-") else { return nil }
                let displayName = components.count > 1 ? components.dropFirst().joined(separator: " ") : nil
                return AntigravityModelEntry(slug: slug, displayName: displayName)
            }
    }

    public static func parseAntigravityModelList(_ output: String) -> [String] {
        parseAntigravityModelEntries(output).map(\.slug)
    }

    private func fetchAntigravityEffortLevels(executable: URL) async throws -> [AgentEffort]? {
        let result = try await runner.run(
            ["--help"],
            executable: executable,
            workingDirectory: FileManager.default.temporaryDirectory
        )
        guard result.exitCode == 0 else { return nil }
        let levels = Self.parseAntigravityEffortLevels(result.stdout)
        return levels.isEmpty ? nil : levels
    }

    /// `agy --help` outputs e.g. "--effort  Reasoning effort for the current CLI session (low|medium|high)".
    public static func parseAntigravityEffortLevels(_ output: String) -> [AgentEffort] {
        guard let effortLine = output.split(separator: "\n").first(where: { $0.contains("--effort") }),
              let open = effortLine.firstIndex(of: "("),
              let close = effortLine[open...].firstIndex(of: ")") else {
            return []
        }
        return effortLine[effortLine.index(after: open)..<close]
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
            description: entry.description,
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
        let description: String?
        let defaultReasoningLevel: String?
        let supportedReasoningLevels: [CodexReasoningLevel]?

        enum CodingKeys: String, CodingKey {
            case slug
            case visibility
            case priority
            case displayName = "display_name"
            case description
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

/// One Antigravity model, grouped from the one-or-more slugs that share a
/// base name — e.g. `gemini-3.7-flash-{low,medium,high}` become a single
/// "Gemini 3.7 Flash" group with three variants. Antigravity bakes reasoning
/// effort into the model slug itself rather than accepting it as a separate
/// flag, so the model picker offers the base name and a second, group-scoped
/// picker offers the variant — see `AgentDescriptor.antigravity.effortFlag`
/// (`nil`: no `--effort` is ever sent) and `AntigravityModelEffortCoordinator`.
public struct AntigravityModelGroup: Sendable, Equatable, Identifiable {
    public let baseSlug: String
    public let displayName: String
    /// Effort level -> the real slug that launches it. Empty when the model
    /// carries no recognized effort suffix at all (e.g. "claude-sonnet-4-6"),
    /// in which case `soleSlug` is the only launchable value.
    public let variants: [AgentEffort: String]
    public let soleSlug: String?

    public var id: String { baseSlug }

    public init(baseSlug: String, displayName: String, variants: [AgentEffort: String], soleSlug: String? = nil) {
        self.baseSlug = baseSlug
        self.displayName = displayName
        self.variants = variants
        self.soleSlug = soleSlug
    }

    /// The slug to launch for a requested effort: the matching variant if
    /// this model has one, else the nearest available rank, else `soleSlug`.
    public func resolvedSlug(for effort: AgentEffort?) -> String? {
        if variants.isEmpty { return soleSlug }
        if let effort, let exact = variants[effort] { return exact }
        guard let effort else {
            return variants[.medium] ?? variants.values.first
        }
        return variants.min { lhs, rhs in
            abs(lhs.key.rank - effort.rank) < abs(rhs.key.rank - effort.rank)
        }?.value
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
        if agent == .antigravity {
            let groups = staticAntigravityGroups()
            return antigravityFallbackModels.map { entry in
                let options = antigravityEffortOptions(for: entry.slug, in: groups)
                return AgentModelProfile(slug: entry.slug, displayName: entry.displayName, effortOptions: options)
            }
        }
        let slugs = staticFallback(for: agent, openCodeSubscription: openCodeSubscription)
        return slugs.map { slug in
            AgentModelProfile(
                slug: slug,
                displayName: displayName(for: slug, agent: agent),
                description: agent == .claudeCode ? claudeModelDescription(for: slug) : nil,
                effortOptions: fallbackEffortOptions(for: agent, slug: slug)
            )
        }
    }

    /// Dispatches to whichever agent keeps a static id -> friendly-name
    /// table, since none of them share a naming scheme. A slug missing from
    /// its agent's table falls back to `nil`, same as before.
    static func displayName(for slug: String, agent: AgentKind) -> String? {
        switch agent {
        case .claudeCode: claudeModelDisplayName(for: slug)
        case .openCode: openCodeModelDisplayName(for: slug)
        case .codexCLI, .antigravity: nil
        }
    }

    /// Claude Code's CLI has no per-model metadata query — `claude --print
    /// "/model"` only lists bare ids like `sonnet` or `opusplan`, unlike
    /// Codex's `debug models` JSON or OpenCode's `--verbose` listing. This
    /// static table supplies the human-facing name and description the model
    /// picker shows, keyed by the ids that command emits. A slug missing here
    /// (a newer CLI's model) falls back to showing its raw id, same as before.
    private static let claudeModelMetadata: [String: (displayName: String, description: String)] = [
        "sonnet": ("Sonnet", "Balanced speed and capability for everyday coding tasks."),
        "opus": ("Opus", "Most capable model — best for complex reasoning and hard problems."),
        "haiku": ("Haiku", "Fastest and most lightweight — best for quick, simple tasks."),
        "fable": ("Fable", "Fast, creative model tuned for writing and ideation."),
        "best": ("Best", "Automatically uses the strongest model available."),
        "opusplan": ("Opus Plan", "Plans with Opus, then executes with Sonnet."),
    ]

    static func claudeModelDisplayName(for slug: String) -> String? {
        claudeModelMetadata[slug]?.displayName
    }

    static func claudeModelDescription(for slug: String) -> String? {
        claudeModelMetadata[slug]?.description
    }

    /// OpenCode's `opencode models <provider>` (without `--verbose`) and the
    /// static fallback list both only carry bare `provider/model` slugs, with
    /// no metadata query to source a friendly name from the way Codex and
    /// Antigravity's CLIs do. This mirrors `claudeModelMetadata`: a hand-kept
    /// table for the ids Flotilla ships as OpenCode's fallback catalog. A
    /// slug missing here (a newer or user-configured OpenCode model) falls
    /// back to showing its raw id, same as every other agent.
    private static let openCodeModelMetadata: [String: String] = [
        "opencode/nemotron-3-ultra-free": "Nemotron 3 Ultra (Free)",
        "opencode/nemotron-3.5-lightning-free": "Nemotron 3.5 Lightning (Free)",
        "opencode/big-pickle": "Big Pickle",
        "opencode/deepseek-v4-flash-free": "DeepSeek V4 Flash (Free)",
        "opencode/hy3-free": "HY3 (Free)",
        "opencode/laguna-s-2.1-free": "Laguna S 2.1 (Free)",
        "opencode/mimo-v2.5-free": "MiMo V2.5 (Free)",
        "opencode-go/deepseek-v4-flash": "DeepSeek V4 Flash",
        "opencode-go/deepseek-v4-pro": "DeepSeek V4 Pro",
        "opencode-go/glm-5.1": "GLM 5.1",
        "opencode-go/glm-5.2": "GLM 5.2",
        "opencode-go/glm-5.3": "GLM 5.3",
        "opencode-go/gpt-5.6-luna": "GPT-5.6 Luna",
        "opencode-go/grok-4.5": "Grok 4.5",
        "opencode-go/hy3": "HY3",
        "opencode-go/kimi-k2.6": "Kimi K2.6",
        "opencode-go/kimi-k2.7-code": "Kimi K2.7 Code",
        "opencode-go/kimi-k3": "Kimi K3",
        "opencode-go/mimo-v2.5": "MiMo V2.5",
        "opencode-go/mimo-v2.5-pro": "MiMo V2.5 Pro",
        "opencode-go/minimax-m2.7": "MiniMax M2.7",
        "opencode-go/minimax-m3": "MiniMax M3",
        "opencode-go/qwen3.6-plus": "Qwen3.6 Plus",
        "opencode-go/qwen3.7-max": "Qwen3.7 Max",
        "opencode-go/qwen3.7-plus": "Qwen3.7 Plus",
        "opencode-go/qwen3.8-max": "Qwen3.8 Max",
        "openrouter/~anthropic/claude-sonnet-latest": "Claude Sonnet (Latest)",
        "openrouter/~anthropic/claude-opus-latest": "Claude Opus (Latest)",
        "openrouter/~anthropic/claude-haiku-latest": "Claude Haiku (Latest)",
        "openrouter/~openai/gpt-latest": "GPT (Latest)",
        "openrouter/~openai/gpt-mini-latest": "GPT Mini (Latest)",
        "openrouter/~x-ai/grok-latest": "Grok (Latest)",
        "openrouter/~deepseek/deepseek-v4-flash-latest": "DeepSeek V4 Flash (Latest)",
        "openrouter/~moonshotai/kimi-latest": "Kimi (Latest)",
        "openrouter/anthropic/claude-3.5-sonnet": "Claude 3.5 Sonnet",
        "openrouter/anthropic/claude-3.5-haiku": "Claude 3.5 Haiku",
        "openrouter/anthropic/claude-3-opus": "Claude 3 Opus",
        "openrouter/openai/gpt-4o": "GPT-4o",
        "openrouter/openai/gpt-4o-mini": "GPT-4o Mini",
        "openrouter/openai/o1": "OpenAI o1",
        "openrouter/openai/o3-mini": "OpenAI o3-mini",
        "openrouter/x-ai/grok-4.5": "Grok 4.5",
        "openrouter/meta-llama/llama-3.3-70b-instruct": "Llama 3.3 70B",
        "openrouter/mistralai/mistral-large": "Mistral Large",
        "openrouter/deepseek/deepseek-chat": "DeepSeek Chat",
        "openrouter/deepseek/deepseek-r1": "DeepSeek R1",
        "openrouter/qwen/qwen-2.5-coder-32b-instruct": "Qwen 2.5 Coder 32B",
        "openrouter/qwen/qwen3-coder": "Qwen3 Coder",
        "openrouter/nvidia/nemotron-3-ultra-550b-a55b": "Nemotron 3 Ultra 550B",
        "openrouter/anthropic/claude-opus-4": "Claude Opus 4",
        "openrouter/anthropic/claude-sonnet-4": "Claude Sonnet 4",
    ]

    static func openCodeModelDisplayName(for slug: String) -> String? {
        openCodeModelMetadata[slug]
    }

    public static func staticAntigravityGroups() -> [AntigravityModelGroup] {
        groupAntigravityModels(antigravityFallbackModels.map { ($0.slug, $0.displayName) })
    }

    /// The trailing `" (low)"`/`" (medium)"`/`" (high)"` a display name uses
    /// to spell out its effort, matched case-insensitively since the CLI's
    /// casing isn't guaranteed. Stripped independent of whether the *slug*
    /// also carries a recognized suffix: a model whose reasoning level is
    /// fixed (no `-low`/`-medium`/`-high` slug variant at all) can still have
    /// this baked into its display name, and leaving it there would show
    /// e.g. "Gemini 3 Flash (high)" as a single, uneditable model name with
    /// no separate effort control to match it.
    private static let displayNameEffortSuffixes = [" (low)", " (medium)", " (high)"]

    private static func stripDisplayNameEffortSuffix(from name: String) -> String {
        let lowercased = name.lowercased()
        guard let suffix = displayNameEffortSuffixes.first(where: lowercased.hasSuffix) else { return name }
        return String(name.dropLast(suffix.count))
    }

    /// Groups Antigravity model entries by base name, splitting off a
    /// recognized trailing `-low`/`-medium`/`-high` slug suffix. The display
    /// name's own effort suffix (see `stripDisplayNameEffortSuffix`) is
    /// always cleaned up, whether or not the slug carries one. An entry
    /// whose slug has no recognized suffix becomes its own single-variant
    /// group — it offers no effort picker, since there's nothing to pick
    /// between, but still gets a clean name.
    public static func groupAntigravityModels(_ entries: [(slug: String, displayName: String?)]) -> [AntigravityModelGroup] {
        let slugSuffixes: [(String, AgentEffort)] = [("-low", .low), ("-medium", .medium), ("-high", .high)]

        struct Parsed {
            let baseSlug: String
            let baseDisplayName: String
            let effort: AgentEffort?
            let slug: String
        }

        let parsed: [Parsed] = entries.map { entry in
            let name = stripDisplayNameEffortSuffix(from: entry.displayName ?? entry.slug)
            guard let (slugSuffix, effort) = slugSuffixes.first(where: { entry.slug.hasSuffix($0.0) }) else {
                return Parsed(baseSlug: entry.slug, baseDisplayName: name, effort: nil, slug: entry.slug)
            }
            let base = String(entry.slug.dropLast(slugSuffix.count))
            return Parsed(baseSlug: base, baseDisplayName: name, effort: effort, slug: entry.slug)
        }

        var order: [String] = []
        var byBase: [String: [Parsed]] = [:]
        for entry in parsed {
            if byBase[entry.baseSlug] == nil { order.append(entry.baseSlug) }
            byBase[entry.baseSlug, default: []].append(entry)
        }

        return order.compactMap { base in
            guard let group = byBase[base], let first = group.first else { return nil }
            var variants: [AgentEffort: String] = [:]
            var soleSlug: String?
            for entry in group {
                if let effort = entry.effort {
                    variants[effort] = entry.slug
                } else {
                    soleSlug = entry.slug
                }
            }
            return AntigravityModelGroup(
                baseSlug: base,
                displayName: first.baseDisplayName,
                variants: variants,
                soleSlug: variants.isEmpty ? (soleSlug ?? first.slug) : nil
            )
        }
    }

    private static let antigravityFallbackModels: [(slug: String, displayName: String)] = [
        ("gemini-3.7-flash-high", "Gemini 3.7 Flash (High)"),
        ("gemini-3.7-flash-medium", "Gemini 3.7 Flash (Medium)"),
        ("gemini-3.7-flash-low", "Gemini 3.7 Flash (Low)"),
        ("gemini-3.6-flash-high", "Gemini 3.6 Flash (High)"),
        ("gemini-3.6-flash-medium", "Gemini 3.6 Flash (Medium)"),
        ("gemini-3.6-flash-low", "Gemini 3.6 Flash (Low)"),
        ("gemini-3.5-flash-high", "Gemini 3.5 Flash (High)"),
        ("gemini-3.5-flash-medium", "Gemini 3.5 Flash (Medium)"),
        ("gemini-3.5-flash-low", "Gemini 3.5 Flash (Low)"),
        ("gemini-3.1-pro-high", "Gemini 3.1 Pro (High)"),
        ("gemini-3.1-pro-low", "Gemini 3.1 Pro (Low)"),
        ("claude-sonnet-4-6", "Claude Sonnet 4.6 (Thinking)"),
        ("claude-opus-4-6-thinking", "Claude Opus 4.6 (Thinking)"),
        ("gpt-oss-120b-medium", "GPT-OSS 120B (Medium)"),
    ]

    static func antigravityEffortOptions(for slug: String, in groups: [AntigravityModelGroup]) -> [AgentEffortOption] {
        let staticOptions = AgentEffortCatalog.staticOptions(for: .antigravity)
        let optionsByLevel = Dictionary(uniqueKeysWithValues: staticOptions.map { ($0.level, $0) })
        guard let group = groups.first(where: { $0.variants.values.contains(slug) || $0.soleSlug == slug }) else {
            return staticOptions
        }
        if group.variants.isEmpty { return [] }
        return group.variants.keys.sorted { $0.rank < $1.rank }.compactMap { optionsByLevel[$0] }
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
        AgentCatalog.descriptor(for: agent).fallbackModels
    }
}

/// Per-agent in-memory cache so repeatedly opening a session-creation
/// surface doesn't re-shell-out on every appearance. Lives for the process
/// lifetime; a newly installed CLI version is picked up on next launch.
public actor ModelCatalogCache {
    public static let shared = ModelCatalogCache()

    private var cache: [AgentKind: [AgentModelProfile]] = [:]
    private var antigravityGroupsCache: [AntigravityModelGroup]?
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

    /// Antigravity's models grouped by base name — see `AntigravityModelGroup`.
    public func antigravityGroups() async -> [AntigravityModelGroup] {
        if let cached = antigravityGroupsCache {
            return cached
        }
        let groups = await fetcher.fetchAntigravityGroups(for: .antigravity)
        antigravityGroupsCache = groups
        return groups
    }
}

import Foundation
import SessionKit

/// One selectable reasoning level, already resolved for a specific agent and
/// model: the agent's own name for it, what it buys, and whether the model
/// falls back to it when no effort is passed.
public struct AgentEffortOption: Sendable, Equatable, Identifiable {
    public let level: AgentEffort
    /// The agent's own name for this level — Codex calls `xhigh` "Extra High",
    /// Claude Code calls it "X-High".
    public let label: String
    public let summary: String
    /// True when the CLI would pick this level on its own for this model.
    public let isModelDefault: Bool

    public var id: AgentEffort { level }

    public init(level: AgentEffort, label: String, summary: String, isModelDefault: Bool = false) {
        self.level = level
        self.label = label
        self.summary = summary
        self.isModelDefault = isModelDefault
    }
}

/// Which reasoning-effort levels each agent — and each of its models — will
/// actually accept, and what each CLI calls them.
///
/// The two CLIs disagree on both counts:
///
/// | | Claude Code (`--effort`) | Codex (`model_reasoning_effort`) | OpenCode |
/// |---|---|---|---|
/// | levels | low, medium, high, xhigh, max | minimal, low, medium, high, xhigh, max, ultra | — |
/// | per model | identical for every model | varies; `codex debug models` is authoritative | — |
/// | top level | `max` | `ultra` ("maximum reasoning with automatic task delegation") |  — |
///
/// Claude Code applies `--effort` uniformly and warns-and-ignores unknown
/// values, so its table is static here. Codex publishes
/// `supported_reasoning_levels` (with descriptions) and a
/// `default_reasoning_level` per model in its own catalog, which
/// `ModelCatalogFetcher` reads — the static tables below are only the offline
/// fallback and can go stale.
public enum AgentEffortCatalog {
    /// Levels the agent's CLI accepts at all, ignoring per-model narrowing.
    public static func supportedLevels(for agent: AgentKind) -> [AgentEffort] {
        AgentCatalog.descriptor(for: agent).effortLevels
    }

    public static func supports(_ level: AgentEffort, agent: AgentKind) -> Bool {
        supportedLevels(for: agent).contains(level)
    }

    /// The agent's own name for a level.
    public static func label(for level: AgentEffort, agent: AgentKind) -> String {
        AgentCatalog.descriptor(for: agent).effortLabel(for: level)
    }

    /// The levels to offer for `agent` + `model`.
    ///
    /// A known model answers for itself. When the model is left to the agent
    /// (empty slug) or isn't in the catalog (a custom slug), the levels every
    /// catalogued model accepts are offered instead — offering the union would
    /// let a user pick something the model actually running then rejects, and
    /// Codex fails the run outright on an unsupported level. Only with no
    /// catalog at all does this fall back to the agent-wide table.
    public static func options(
        for agent: AgentKind,
        model: String?,
        profiles: [AgentModelProfile] = []
    ) -> [AgentEffortOption] {
        guard agent.supportsEffortSelection else { return [] }

        let slug = model?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !slug.isEmpty, let profile = profiles.first(where: { $0.slug == slug }) {
            // A cataloged model answers for itself, even when that answer is
            // "no levels" — e.g. an Antigravity model with no effort variant
            // at all shouldn't inherit levels from other models in the same
            // catalog just because its own list is empty.
            return profile.effortOptions
        }
        let shared = optionsSharedByEveryModel(in: profiles)
        return shared.isEmpty ? staticOptions(for: agent) : shared
    }

    /// Levels present in *every* profile, described by the first profile that
    /// lists them. The "model default" flag is dropped: which level a model
    /// falls back to differs per model, so it means nothing until one is picked.
    static func optionsSharedByEveryModel(in profiles: [AgentModelProfile]) -> [AgentEffortOption] {
        guard let first = profiles.first(where: { !$0.effortOptions.isEmpty }) else { return [] }
        let candidates = profiles.filter { !$0.effortOptions.isEmpty }
        return first.effortOptions.compactMap { option in
            guard candidates.allSatisfy({ $0.effortOptions.contains(where: { $0.level == option.level }) }) else {
                return nil
            }
            return AgentEffortOption(
                level: option.level,
                label: option.label,
                summary: option.summary,
                isModelDefault: false
            )
        }
    }

    /// Snaps `level` into `options`, preferring the nearest supported rank so a
    /// user who picked Ultra on a Codex model keeps the deepest available level
    /// after switching to a model (or agent) that stops at X-High.
    public static func clamp(_ level: AgentEffort, to options: [AgentEffortOption]) -> AgentEffort? {
        guard !options.isEmpty else { return nil }
        if options.contains(where: { $0.level == level }) { return level }
        return options.min { lhs, rhs in
            abs(lhs.level.rank - level.rank) < abs(rhs.level.rank - level.rank)
        }?.level
    }

    /// Agent-level table used when no per-model profile is available.
    public static func staticOptions(for agent: AgentKind) -> [AgentEffortOption] {
        supportedLevels(for: agent).map { level in
            AgentEffortOption(
                level: level,
                label: label(for: level, agent: agent),
                summary: summary(for: level, agent: agent),
                isModelDefault: false
            )
        }
    }

    /// Fallback copy for levels whose description the CLI doesn't publish
    /// (Claude Code publishes none; Codex publishes one per level per model).
    public static func summary(for level: AgentEffort, agent: AgentKind) -> String {
        switch level {
        case .minimal: "The least reasoning the model will do."
        case .low: "Fast responses with lighter reasoning."
        case .medium: "Balances speed and depth for everyday tasks."
        case .high: "Greater reasoning depth for complex problems."
        case .xhigh: "Extra reasoning depth for hard problems."
        case .max: "Maximum reasoning depth for the hardest tasks."
        case .ultra: "Maximum reasoning with automatic task delegation."
        }
    }

    /// How the level reaches the CLI, shown in the picker so the mapping from
    /// this control to the agent's own flag stays visible.
    public static func invocationHint(for level: AgentEffort, agent: AgentKind) -> String? {
        AgentCatalog.descriptor(for: agent).invocationHint(for: level)
    }
}

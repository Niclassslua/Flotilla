import Foundation
import SwiftUI
import SessionKit
import AgentKit

/// Coordinates the model and reasoning-effort controls for agents that bake
/// effort into the model slug (Antigravity and Cursor Agent).
///
/// Those CLIs have no `--effort` flag. This coordinator:
/// - Hides the effort picker when the selected model has no variants (Cursor's
///   Auto and Composer, Antigravity's fixed-slug models).
/// - Reflects the effort encoded in the current slug back to `EffortLevelPicker`.
/// - When the user changes effort, writes the matching variant slug into `draft.model`.
/// - Leaves Claude, Codex, and OpenCode's direct effort binding untouched.
@Observable
@MainActor
final class AntigravityModelEffortCoordinator {
    var groups: [AntigravityModelGroup]
    private var loadedAgent: AgentKind?

    init(groups: [AntigravityModelGroup] = ModelCatalog.staticAntigravityGroups()) {
        self.groups = groups
    }

    func refresh(for agent: AgentKind) async {
        guard agent.bakesEffortIntoModelSlug else {
            loadedAgent = agent
            groups = []
            return
        }
        loadedAgent = agent
        groups = Self.staticGroups(for: agent)
        let live = await Self.liveGroups(for: agent)
        guard loadedAgent == agent, !live.isEmpty else { return }
        groups = live
    }

    func supportsEffort(for draft: SessionDraft) -> Bool {
        guard draft.agent.supportsEffortSelection else { return false }
        guard draft.agent.bakesEffortIntoModelSlug else { return true }
        let trimmed = draft.model.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return true }
        guard let group = group(for: trimmed, agent: draft.agent) else { return false }
        return !group.variants.isEmpty
    }

    func group(for slug: String) -> AntigravityModelGroup? {
        group(for: slug, agent: loadedAgent ?? .antigravity)
    }

    func currentEffort(for draft: SessionDraft) -> AgentEffort {
        if draft.agent.bakesEffortIntoModelSlug, let group = group(for: draft.model, agent: draft.agent) {
            for (lvl, s) in group.variants where s == draft.model {
                return lvl
            }
        }
        return draft.effort
    }

    func effortBinding(for draft: SessionDraft) -> Binding<AgentEffort> {
        Binding(
            get: { [weak self] in
                self?.currentEffort(for: draft) ?? draft.effort
            },
            set: { [weak self] newEffort in
                draft.effort = newEffort
                guard draft.agent.bakesEffortIntoModelSlug, let self else { return }
                let catalog = self.catalog(for: draft.agent)
                if let group = catalog.first(where: { Self.matches($0, slug: draft.model) }) {
                    if let resolved = group.resolvedSlug(for: newEffort) {
                        draft.model = resolved
                    }
                } else if draft.model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                          let defaultGroup = catalog.first(where: { !$0.variants.isEmpty }) {
                    if let resolved = defaultGroup.resolvedSlug(for: newEffort) {
                        draft.model = resolved
                    }
                }
            }
        )
    }

    private func group(for slug: String, agent: AgentKind) -> AntigravityModelGroup? {
        let trimmed = slug.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return catalog(for: agent).first { Self.matches($0, slug: trimmed) }
    }

    private func catalog(for agent: AgentKind) -> [AntigravityModelGroup] {
        if loadedAgent == agent { return groups }
        return Self.staticGroups(for: agent)
    }

    private static func matches(_ group: AntigravityModelGroup, slug: String) -> Bool {
        group.variants.values.contains(slug) || group.soleSlug == slug || group.baseSlug == slug
    }

    private static func staticGroups(for agent: AgentKind) -> [AntigravityModelGroup] {
        switch agent {
        case .antigravity: ModelCatalog.staticAntigravityGroups()
        case .cursorAgent: ModelCatalog.staticCursorGroups()
        case .claudeCode, .codexCLI, .openCode: []
        }
    }

    private static func liveGroups(for agent: AgentKind) async -> [AntigravityModelGroup] {
        switch agent {
        case .antigravity: await ModelCatalogCache.shared.antigravityGroups()
        case .cursorAgent: await ModelCatalogCache.shared.cursorGroups()
        case .claudeCode, .codexCLI, .openCode: []
        }
    }
}

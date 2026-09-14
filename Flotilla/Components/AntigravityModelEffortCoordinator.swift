import Foundation
import SwiftUI
import SessionKit
import AgentKit

/// Coordinates the model and reasoning-effort controls when configuring an
/// Antigravity session.
///
/// Antigravity bakes reasoning effort directly into the model slug itself
/// (e.g. `gemini-3.7-flash-high`) rather than accepting `--effort` as a
/// separate CLI flag. For Antigravity, this coordinator bridges the UI:
/// - Determines whether the selected model has effort variants (models with no
///   recognized suffix, like Claude Sonnet 4.6, hide the effort picker).
/// - Reflects the effort variant encoded in the current model slug back to
///   `EffortLevelPicker`.
/// - When the user changes reasoning effort, resolves the selected base model
///   and new effort back into the launchable slug and writes it into `draft.model`.
/// - Leaves every other agent's direct effort binding untouched.
@Observable
@MainActor
final class AntigravityModelEffortCoordinator {
    var groups: [AntigravityModelGroup]

    init(groups: [AntigravityModelGroup] = ModelCatalog.staticAntigravityGroups()) {
        self.groups = groups
    }

    func refresh() async {
        let live = await ModelCatalogCache.shared.antigravityGroups()
        if !live.isEmpty {
            self.groups = live
        }
    }

    func supportsEffort(for draft: SessionDraft) -> Bool {
        guard draft.agent.supportsEffortSelection else { return false }
        guard draft.agent == .antigravity else { return true }
        let trimmed = draft.model.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return true }
        guard let group = group(for: trimmed) else { return false }
        return !group.variants.isEmpty
    }

    func group(for slug: String) -> AntigravityModelGroup? {
        let trimmed = slug.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return groups.first { g in
            g.variants.values.contains(trimmed) || g.soleSlug == trimmed || g.baseSlug == trimmed
        }
    }

    func currentEffort(for draft: SessionDraft) -> AgentEffort {
        if draft.agent == .antigravity, let group = group(for: draft.model) {
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
                guard draft.agent == .antigravity, let self else { return }
                if let group = self.group(for: draft.model) {
                    if let resolved = group.resolvedSlug(for: newEffort) {
                        draft.model = resolved
                    }
                } else if draft.model.isEmpty, let defaultGroup = self.groups.first {
                    if let resolved = defaultGroup.resolvedSlug(for: newEffort) {
                        draft.model = resolved
                    }
                }
            }
        )
    }
}

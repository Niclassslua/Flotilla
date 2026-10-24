import SessionKit
import SettingsKit

extension SessionDefaults {
    /// The agents the user works with, in catalogue order. Every agent when
    /// they never chose, so settings from before the choice behave as before.
    var enabledAgents: [AgentKind] {
        guard let raw = enabledAgentRawValues else { return AgentKind.allCases }
        let chosen = AgentKind.allCases.filter { raw.contains($0.rawValue) }
        return chosen.isEmpty ? AgentKind.allCases : chosen
    }

    /// Whether the user has chosen at all — `nil` keeps the old defaults.
    var hasChosenAgents: Bool { enabledAgentRawValues != nil }

    /// Saves the choice and keeps the default agent inside it. An empty set
    /// is ignored: there is always at least one agent to launch.
    mutating func setEnabledAgents(_ agents: Set<AgentKind>) {
        guard !agents.isEmpty else { return }
        enabledAgentRawValues = AgentKind.allCases.filter { agents.contains($0) }.map(\.rawValue)
        if let current = AgentKind(rawValue: defaultAgentRawValue), agents.contains(current) { return }
        defaultAgentRawValue = enabledAgents[0].rawValue
    }
}

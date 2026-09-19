import SwiftUI
import SessionKit
import SettingsKit
import DesignSystem

/// Per-widget settings: a project filter on every widget, a time window on
/// the ones that have one, and an agent filter on the two that need it.
/// Opened from the (i) badge in edit mode or "Edit Widget…" in the context
/// menu — either way it writes straight through `HomeWidgetEditor
/// .updateConfig`, which commits immediately outside an edit session.
struct HomeWidgetSettingsPopover: View {
    let kind: HomeWidgetKind
    let entry: HomeWidgetEntry
    @Bindable var store: AppStore
    let editor: HomeWidgetEditor

    @State private var projectID: String?
    @State private var timeWindowDays: Int?
    @State private var agent: String?

    var body: some View {
        VStack(alignment: .leading, spacing: FlotillaSpacing.medium) {
            Text("\(kind.title) settings")
                .font(FlotillaTypography.headline)
            if kind.hasProjectFilter {
                labeled("Project") {
                    Picker("Project", selection: $projectID) {
                        Text("All projects").tag(String?.none)
                        ForEach(store.projects) { project in
                            Text(project.name).tag(Optional(project.id.uuidString))
                        }
                    }
                    .labelsHidden()
                }
            }
            if let options = kind.timeWindowOptionsDays {
                labeled("Time window") {
                    Picker("Time window", selection: $timeWindowDays) {
                        ForEach(options, id: \.self) { days in
                            Text("\(days) days").tag(Optional(days))
                        }
                    }
                    .labelsHidden()
                }
            }
            if kind.hasAgentFilter {
                labeled("Agent") {
                    Picker("Agent", selection: $agent) {
                        Text("All agents").tag(String?.none)
                        ForEach(AgentKind.allCases) { agentKind in
                            Text(agentKind.displayName).tag(Optional(agentKind.rawValue))
                        }
                    }
                    .labelsHidden()
                }
            }
        }
        .padding(FlotillaSpacing.large)
        .frame(width: 260)
        .onAppear {
            projectID = entry.config.projectID
            timeWindowDays = entry.config.timeWindowDays ?? kind.defaultTimeWindowDays
            agent = entry.config.agent
        }
        .onChange(of: projectID) { _, _ in commit() }
        .onChange(of: timeWindowDays) { _, _ in commit() }
        .onChange(of: agent) { _, _ in commit() }
        .accessibilityIdentifier(AXID.homeWidgetSettingsPopover.rawValue)
    }

    private func labeled(_ title: String, @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(FlotillaTypography.caption).foregroundStyle(FlotillaColors.textSecondary)
            content()
        }
    }

    private func commit() {
        editor.updateConfig(
            id: entry.id,
            config: HomeWidgetConfig(
                projectID: projectID,
                timeWindowDays: timeWindowDays == kind.defaultTimeWindowDays ? nil : timeWindowDays,
                agent: agent
            )
        )
    }
}

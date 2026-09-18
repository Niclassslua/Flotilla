import SwiftUI
import SessionKit
import AgentKit
import DesignSystem

/// **Redesign B — Project Rail.** Where first, then what.
///
/// Project choice is the decision most often changed and the one the old bar
/// hid behind a chip, so it gets a permanent, searchable rail on the left.
/// The right pane reads top to bottom: which project you're in, the goal as a
/// real multi-line editor, the agent as a full-width segmented row, and the
/// finer knobs on a single line underneath.
struct ProjectRailDesign: View {
    @Bindable var draft: SessionDraft
    @Bindable var store: AppStore
    let actions: SessionLauncherActions

    @State private var coordinator = AntigravityModelEffortCoordinator()

    var body: some View {
        HStack(spacing: 0) {
            rail
            Divider().overlay(FlotillaColors.separator)
            main
        }
        .frame(height: 400)
        .launcherSurface()
        .background { LauncherHiddenShortcuts(actions: actions) }
        .task(id: draft.agent) { await coordinator.refresh() }
    }

    private var rail: some View {
        VStack(alignment: .leading, spacing: FlotillaSpacing.small) {
            LauncherEyebrow("Projects")
                .padding(.horizontal, FlotillaSpacing.small)
            ScrollView {
                LauncherProjectList(draft: draft)
            }
            .scrollIndicators(.never)
        }
        .padding(FlotillaSpacing.medium)
        .padding(.top, FlotillaSpacing.xSmall)
        .frame(width: 250)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(FlotillaColors.surfaceElevated.opacity(0.3))
    }

    private var main: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
                .padding(.horizontal, FlotillaSpacing.xLarge)
                .padding(.top, FlotillaSpacing.large)

            LauncherGoalField(draft: draft, actions: actions, fontSize: 19, lines: 4...9)
                .frame(maxHeight: .infinity, alignment: .topLeading)
                .padding(.horizontal, FlotillaSpacing.xLarge)
                .padding(.top, FlotillaSpacing.large)

            VStack(alignment: .leading, spacing: FlotillaSpacing.medium) {
                LauncherAgentSegments(draft: draft, fillsWidth: true)
                HStack(spacing: FlotillaSpacing.small) {
                    LauncherModelControls(draft: draft, coordinator: coordinator)
                    SessionModeToggle(mode: $draft.initialMode, accessibilityIdentifier: "CreateSession.ModePicker")
                    Spacer(minLength: 0)
                    LauncherIsolationPicker(draft: draft)
                }
                LauncherErrorBanner(store: store)
            }
            .padding(.horizontal, FlotillaSpacing.xLarge)
            .padding(.bottom, FlotillaSpacing.large)

            Divider().overlay(FlotillaColors.separator)

            HStack(spacing: FlotillaSpacing.medium) {
                LauncherPreviewText(preview: draft.preview)
                Spacer(minLength: FlotillaSpacing.small)
                LauncherLaunchButtons(draft: draft, actions: actions, showsCancel: false)
            }
            .padding(.horizontal, FlotillaSpacing.xLarge)
            .padding(.vertical, FlotillaSpacing.medium)
        }
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: FlotillaSpacing.small) {
            Text("New session")
                .font(FlotillaTypography.headline)
                .foregroundStyle(FlotillaColors.textPrimary)
            Text("in")
                .font(FlotillaTypography.callout)
                .foregroundStyle(FlotillaColors.textTertiary)
            Text(draft.projectChoice.displayName)
                .font(FlotillaTypography.callout.weight(.semibold))
                .foregroundStyle(draft.projectChoice.isGeneral ? FlotillaColors.textSecondary : FlotillaColors.accent)
            Spacer(minLength: 0)
            Button { actions.cancel() } label: {
                LauncherKeycap("esc")
            }
            .buttonStyle(.plain)
            .help("Cancel (Esc)")
            .accessibilityIdentifier("CreateSession.CancelButton")
            .accessibilityLabel("Cancel")
        }
    }
}

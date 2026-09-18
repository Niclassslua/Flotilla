import SwiftUI
import SessionKit
import AgentKit
import DesignSystem

/// **Redesign A — Control Deck.** The Command Bar, given room to breathe.
///
/// The goal field stays on top and gets two resting lines instead of one.
/// Everything the old single chip strip crammed side by side moves into a
/// recessed deck with one labeled row per decision — Agent, Model, Workspace —
/// so each control has a name and space for its own words. The footer keeps
/// the launch preview and spells the shortcuts out on the buttons.
struct ControlDeckDesign: View {
    @Bindable var draft: SessionDraft
    @Bindable var store: AppStore
    let actions: SessionLauncherActions

    @State private var coordinator = AntigravityModelEffortCoordinator()

    private let labelWidth: CGFloat = 84

    var body: some View {
        VStack(spacing: 0) {
            goalArea
            Divider().overlay(FlotillaColors.separator)
            deck
            LauncherErrorBanner(store: store)
                .padding(.horizontal, FlotillaSpacing.large)
                .padding(.bottom, FlotillaSpacing.small)
            Divider().overlay(FlotillaColors.separator)
            footer
        }
        .launcherSurface()
        .background { LauncherHiddenShortcuts(actions: actions) }
        .task(id: draft.agent) { await coordinator.refresh() }
    }

    private var goalArea: some View {
        HStack(alignment: .top, spacing: FlotillaSpacing.medium) {
            ProviderLogo(agent: draft.agent)
                .frame(width: FlotillaIconSize.xLarge, height: FlotillaIconSize.xLarge)
                .padding(.top, 1)
            LauncherGoalField(draft: draft, actions: actions, fontSize: 19, lines: 2...6)
        }
        .padding(.horizontal, FlotillaSpacing.xLarge)
        .padding(.top, FlotillaSpacing.xLarge)
        .padding(.bottom, FlotillaSpacing.large)
    }

    private var deck: some View {
        VStack(spacing: FlotillaSpacing.medium) {
            deckRow("Agent") {
                LauncherAgentSegments(draft: draft)
                Spacer(minLength: 0)
            }
            deckRow("Model") {
                LauncherModelControls(draft: draft, coordinator: coordinator)
                Spacer(minLength: 0)
                SessionModeToggle(mode: $draft.initialMode, accessibilityIdentifier: "CreateSession.ModePicker")
            }
            deckRow("Workspace") {
                LauncherProjectButton(draft: draft) { projectLabel }
                Spacer(minLength: 0)
                LauncherIsolationPicker(draft: draft)
            }
        }
        .padding(.horizontal, FlotillaSpacing.xLarge)
        .padding(.vertical, FlotillaSpacing.large)
        .background(FlotillaColors.surfaceElevated.opacity(0.25))
    }

    private func deckRow<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        HStack(spacing: FlotillaSpacing.medium) {
            LauncherEyebrow(title)
                .frame(width: labelWidth, alignment: .leading)
            content()
        }
        .frame(minHeight: 28)
    }

    private var projectLabel: some View {
        HStack(spacing: FlotillaSpacing.small) {
            Image(systemName: draft.projectChoice.symbolName)
                .font(.system(size: FlotillaIconSize.small))
                .foregroundStyle(draft.projectChoice.isGeneral ? FlotillaColors.textSecondary : FlotillaColors.accent)
            Text(draft.projectChoice.displayName)
                .font(FlotillaTypography.caption.weight(.semibold))
                .foregroundStyle(FlotillaColors.textPrimary)
            if let path = draft.projectChoice.displayPath {
                Text(path)
                    .font(FlotillaTypography.caption2)
                    .foregroundStyle(FlotillaColors.textTertiary)
                    .lineLimit(1)
                    .truncationMode(.head)
                    .frame(maxWidth: 200, alignment: .leading)
            }
            Image(systemName: "chevron.up.chevron.down")
                .font(.system(size: 8, weight: .semibold))
                .foregroundStyle(FlotillaColors.textTertiary)
        }
        .padding(.horizontal, 10)
        .frame(height: 28)
        .background(FlotillaColors.surfaceElevated.opacity(0.7), in: RoundedRectangle(cornerRadius: FlotillaRadius.control + 1, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: FlotillaRadius.control + 1, style: .continuous)
                .strokeBorder(FlotillaColors.separator, lineWidth: FlotillaBorderWidth.hairline)
        }
        .contentShape(Rectangle())
    }

    private var footer: some View {
        HStack(spacing: FlotillaSpacing.medium) {
            LauncherPreviewText(preview: draft.preview)
            Spacer(minLength: FlotillaSpacing.small)
            LauncherLaunchButtons(draft: draft, actions: actions)
        }
        .padding(.horizontal, FlotillaSpacing.xLarge)
        .padding(.vertical, FlotillaSpacing.medium)
    }
}

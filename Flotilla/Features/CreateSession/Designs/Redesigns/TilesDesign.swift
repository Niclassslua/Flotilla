import SwiftUI
import SessionKit
import AgentKit
import DesignSystem

/// **Redesign C — Tiles.** Three decisions, three cards.
///
/// Under a generous goal field sit three equal tiles — Workspace, Agent and
/// Launch — each with a title, its current value in large type, and the
/// controls that change it. The Launch tile promotes the preview from a dim
/// footer line to a first-class answer to "what exactly happens if I hit ↩?".
struct TilesDesign: View {
    @Bindable var draft: SessionDraft
    @Bindable var store: AppStore
    let actions: SessionLauncherActions

    @State private var coordinator = AntigravityModelEffortCoordinator()

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            LauncherGoalField(draft: draft, actions: actions, fontSize: 20, lines: 2...6)
                .padding(.horizontal, FlotillaSpacing.xLarge)
                .padding(.top, FlotillaSpacing.xLarge)
                .padding(.bottom, FlotillaSpacing.large)

            HStack(alignment: .top, spacing: FlotillaSpacing.medium) {
                workspaceTile
                agentTile
                launchTile
            }
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, FlotillaSpacing.large)

            LauncherErrorBanner(store: store)
                .padding(.horizontal, FlotillaSpacing.large)
                .padding(.top, FlotillaSpacing.small)

            HStack(spacing: FlotillaSpacing.medium) {
                Text("⇧↩ new line  ·  ⌘↩ launch from any control")
                    .font(FlotillaTypography.caption2)
                    .foregroundStyle(FlotillaColors.textTertiary)
                Spacer(minLength: FlotillaSpacing.small)
                LauncherLaunchButtons(draft: draft, actions: actions)
            }
            .padding(.horizontal, FlotillaSpacing.xLarge)
            .padding(.vertical, FlotillaSpacing.large)
        }
        .launcherSurface()
        .background { LauncherHiddenShortcuts(actions: actions) }
        .task(id: draft.agent) { await coordinator.refresh() }
    }

    // MARK: - Tiles

    private func tile<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: FlotillaSpacing.medium) {
            LauncherEyebrow(title)
            content()
        }
        .padding(FlotillaSpacing.medium + 2)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(FlotillaColors.surfaceElevated.opacity(0.45), in: RoundedRectangle(cornerRadius: FlotillaRadius.card + 2, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: FlotillaRadius.card + 2, style: .continuous)
                .strokeBorder(FlotillaColors.separator, lineWidth: FlotillaBorderWidth.hairline)
        }
    }

    private var workspaceTile: some View {
        tile("Workspace") {
            LauncherProjectButton(draft: draft) {
                HStack(alignment: .top, spacing: FlotillaSpacing.small) {
                    Image(systemName: draft.projectChoice.symbolName)
                        .font(.system(size: FlotillaIconSize.medium))
                        .foregroundStyle(draft.projectChoice.isGeneral ? FlotillaColors.textSecondary : FlotillaColors.accent)
                        .frame(width: FlotillaIconSize.large)
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 4) {
                            Text(draft.projectChoice.displayName)
                                .font(.system(size: 14, weight: .semibold))
                                .foregroundStyle(FlotillaColors.textPrimary)
                                .lineLimit(1)
                            Image(systemName: "chevron.down")
                                .font(.system(size: 8, weight: .bold))
                                .foregroundStyle(FlotillaColors.textTertiary)
                        }
                        Text(draft.projectChoice.displayPath ?? "Scratch folder")
                            .font(FlotillaTypography.caption2)
                            .foregroundStyle(FlotillaColors.textTertiary)
                            .lineLimit(1)
                            .truncationMode(.head)
                    }
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            Spacer(minLength: 0)
            LauncherIsolationPicker(draft: draft, fillsWidth: true)
        }
    }

    private var agentTile: some View {
        tile("Agent") {
            HStack(spacing: FlotillaSpacing.small) {
                ProviderLogo(agent: draft.agent)
                    .frame(width: FlotillaIconSize.large, height: FlotillaIconSize.large)
                Text(draft.agent.displayName)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(FlotillaColors.textPrimary)
                Spacer(minLength: 0)
            }
            LauncherAgentSegments(draft: draft, showsNames: false, fillsWidth: true)
            LauncherModelControls(draft: draft, coordinator: coordinator)
        }
    }

    private var launchTile: some View {
        let preview = draft.preview
        return tile("Launch") {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    if preview.isWorktree {
                        GitBranchIcon(size: FlotillaIconSize.small)
                            .foregroundStyle(FlotillaColors.statusReady)
                    } else {
                        Image(systemName: "shippingbox")
                            .font(.system(size: FlotillaIconSize.small))
                            .foregroundStyle(FlotillaColors.textTertiary)
                    }
                    Text(preview.isWorktree ? "New worktree" : (draft.projectChoice.isGeneral ? "Scratch folder" : "Main checkout"))
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(FlotillaColors.textPrimary)
                }
                Text(preview.displayBranch ?? preview.displayDirectory)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(FlotillaColors.textSecondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text("$ \(preview.command)")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(FlotillaColors.textTertiary)
                    .lineLimit(1)
                if preview.sharedCheckoutWarning != nil {
                    Label("Shared checkout", systemImage: "exclamationmark.triangle.fill")
                        .font(FlotillaTypography.caption2.weight(.medium))
                        .foregroundStyle(FlotillaColors.warning)
                        .help(preview.sharedCheckoutWarning ?? "")
                }
            }
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("CreateSession.LaunchSummary")
            Spacer(minLength: 0)
            SessionModeToggle(mode: $draft.initialMode, accessibilityIdentifier: "CreateSession.ModePicker")
        }
    }
}

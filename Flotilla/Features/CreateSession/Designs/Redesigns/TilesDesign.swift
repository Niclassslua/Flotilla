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
    @State private var isWorkspacePickerPresented = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            LauncherGoalField(draft: draft, actions: actions, fontSize: 20, lines: 2...6)
                .padding(.horizontal, FlotillaSpacing.xLarge)
                .padding(.top, FlotillaSpacing.xLarge)
                .padding(.bottom, FlotillaSpacing.large)

            HStack(alignment: .top, spacing: FlotillaSpacing.medium) {
                workspaceTile
                    // The project list is an in-window overlay. Its card,
                    // rather than only the button inside it, must sit above
                    // the other two HStack siblings while it is open.
                    .zIndex(isWorkspacePickerPresented ? 1 : 0)
                agentTile
                launchTile
            }
            // `zIndex` only orders siblings in the same container. The
            // picker is also allowed to extend below this HStack, where it
            // overlaps the error and action rows that are siblings of the
            // HStack in the surrounding VStack. Raise the whole row while
            // the in-window menu is open so those later rows cannot cover it.
            .zIndex(isWorkspacePickerPresented ? 1 : 0)
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
                LauncherLaunchButtons(draft: draft, actions: actions, showsCancel: false)
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
            TilesWorkspacePicker(
                draft: draft,
                isPresented: $isWorkspacePickerPresented
            )
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

/// The workspace control deliberately uses the same compact chip language as
/// the model and reasoning-effort controls in the adjacent Agent tile.
private struct TilesWorkspacePicker: View {
    @Bindable var draft: SessionDraft
    @Binding var isPresented: Bool

    @State private var isHovering = false

    var body: some View {
        LauncherProjectButton(
            draft: draft,
            label: {
                HStack(spacing: 6) {
                    Image(systemName: draft.projectChoice.symbolName)
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(draft.projectChoice.isGeneral ? FlotillaColors.textTertiary : FlotillaColors.accent)

                    Text(draft.projectChoice.displayName)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(draft.projectChoice.isGeneral ? FlotillaColors.textSecondary : FlotillaColors.textPrimary)
                        .lineLimit(1)

                    Image(systemName: "chevron.up.chevron.down")
                        .font(.system(size: 8, weight: .semibold))
                        .foregroundStyle(FlotillaColors.textTertiary)
                }
                .padding(.horizontal, 9)
                .padding(.vertical, 5)
                .background(
                    isHovering ? FlotillaColors.surfaceElevated : FlotillaColors.surfaceElevated.opacity(0.7),
                    in: Capsule()
                )
                .overlay {
                    Capsule().strokeBorder(
                        isHovering ? FlotillaColors.accent.opacity(0.6) : FlotillaColors.separator,
                        lineWidth: FlotillaBorderWidth.hairline
                    )
                }
                .contentShape(Capsule())
            },
            presentationChanged: { isPresented = $0 }
        )
        .onHover { isHovering = $0 }
    }
}

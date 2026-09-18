import SwiftUI
import SessionKit
import AgentKit
import DesignSystem

/// **Redesign D — Sentence.** The configuration reads like what it does.
///
/// Instead of a row of unlabeled chips, the settings are the blanks of one
/// sentence — "Run Claude Code with Opus in Flotilla on a new worktree" —
/// where every underlined value is the control that changes it. Below it, a
/// terminal-style block shows the literal command and destination.
struct SentenceDesign: View {
    @Bindable var draft: SessionDraft
    @Bindable var store: AppStore
    let actions: SessionLauncherActions

    @State private var coordinator = AntigravityModelEffortCoordinator()

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            LauncherGoalField(draft: draft, actions: actions, placeholder: "What should the agent do?   @ project   / agent", fontSize: 22, lines: 2...6)
                .padding(.horizontal, FlotillaSpacing.xLarge + 4)
                .padding(.top, FlotillaSpacing.xLarge + 4)
                .padding(.bottom, FlotillaSpacing.xLarge)

            sentence
                .padding(.horizontal, FlotillaSpacing.xLarge + 4)

            terminal
                .padding(.horizontal, FlotillaSpacing.xLarge)
                .padding(.top, FlotillaSpacing.large)

            LauncherErrorBanner(store: store)
                .padding(.horizontal, FlotillaSpacing.xLarge)
                .padding(.top, FlotillaSpacing.small)

            HStack {
                Spacer(minLength: 0)
                LauncherLaunchButtons(draft: draft, actions: actions)
            }
            .padding(.horizontal, FlotillaSpacing.xLarge)
            .padding(.vertical, FlotillaSpacing.large)
        }
        .launcherSurface()
        .background { LauncherHiddenShortcuts(actions: actions) }
        .task(id: draft.agent) { await coordinator.refresh() }
    }

    // MARK: - Sentence

    private var sentence: some View {
        LauncherFlowLayout(spacing: 6, lineSpacing: 8) {
            word("Run")
            agentMenu
            word("with")
            LauncherModelControls(draft: draft, coordinator: coordinator)
            word("in")
            LauncherProjectButton(draft: draft) {
                blank(symbol: draft.projectChoice.symbolName, text: draft.projectChoice.displayName)
            }
            if draft.supportsWorktree {
                word("on")
                isolationMenu
            }
            word("·")
            SessionModeToggle(mode: $draft.initialMode, accessibilityIdentifier: "CreateSession.ModePicker")
        }
    }

    private func word(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 15))
            .foregroundStyle(FlotillaColors.textTertiary)
            .frame(height: 26)
    }

    private func blank(symbol: String? = nil, logo: AgentKind? = nil, text: String) -> some View {
        HStack(spacing: 5) {
            if let logo {
                ProviderLogo(agent: logo).frame(width: 14, height: 14)
            } else if symbol == "arrow.triangle.branch" {
                GitBranchIcon(size: 12)
                    .foregroundStyle(FlotillaColors.accent)
            } else if let symbol {
                Image(systemName: symbol)
                    .font(.system(size: 11))
                    .foregroundStyle(FlotillaColors.accent)
            }
            Text(text)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(FlotillaColors.textPrimary)
            Image(systemName: "chevron.down")
                .font(.system(size: 8, weight: .bold))
                .foregroundStyle(FlotillaColors.textTertiary)
        }
        .padding(.bottom, 2)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(FlotillaColors.accent.opacity(0.55))
                .frame(height: 1.5)
        }
        .frame(height: 26)
        .contentShape(Rectangle())
    }

    private var agentMenu: some View {
        Menu {
            ForEach(AgentKind.allCases) { kind in
                Button {
                    draft.selectAgent(kind)
                } label: {
                    Label { Text(kind.displayName) } icon: { ProviderLogoAsset(agent: kind).image }
                }
                .accessibilityIdentifier("CreateSession.Agent.\(kind.rawValue)")
            }
        } label: {
            blank(logo: draft.agent, text: draft.agent.displayName)
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .accessibilityIdentifier("CreateSession.AgentPicker")
    }

    private var isolationMenu: some View {
        Menu {
            Button("a new worktree") { draft.createWorktree = true }
                .accessibilityIdentifier("CreateSession.Checkout.Worktree")
            Button("the main checkout") { draft.createWorktree = false }
                .accessibilityIdentifier("CreateSession.Checkout.Main")
        } label: {
            blank(symbol: draft.createWorktree ? "arrow.triangle.branch" : "shippingbox",
                  text: draft.createWorktree ? "a new worktree" : "the main checkout")
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
    }

    // MARK: - Terminal

    private var terminal: some View {
        let preview = draft.preview
        return VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 6) {
                Text("$").foregroundStyle(FlotillaColors.accent)
                Text(preview.command).foregroundStyle(FlotillaColors.textPrimary)
            }
            HStack(spacing: 6) {
                if preview.isWorktree {
                    GitBranchIcon(size: FlotillaIconSize.xSmall)
                        .foregroundStyle(FlotillaColors.statusReady)
                    Text(preview.displayBranch ?? "").foregroundStyle(FlotillaColors.statusReady)
                    Text("→").foregroundStyle(FlotillaColors.textTertiary)
                } else {
                    Text("cd").foregroundStyle(FlotillaColors.textTertiary)
                }
                Text(preview.displayDirectory)
                    .foregroundStyle(FlotillaColors.textTertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            if let warning = preview.sharedCheckoutWarning {
                Label(warning, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(FlotillaColors.warning)
                    .lineLimit(1)
            }
        }
        .font(.system(size: 11.5, design: .monospaced))
        .padding(.horizontal, FlotillaSpacing.medium + 2)
        .padding(.vertical, FlotillaSpacing.medium)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(FlotillaColors.terminalCanvas.opacity(0.85), in: RoundedRectangle(cornerRadius: FlotillaRadius.card, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: FlotillaRadius.card, style: .continuous)
                .strokeBorder(FlotillaColors.separator, lineWidth: FlotillaBorderWidth.hairline)
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("CreateSession.LaunchSummary")
    }
}

/// Wraps its children onto new lines like text, so the sentence reflows when
/// a long project or model name doesn't fit.
struct LauncherFlowLayout: Layout {
    var spacing: CGFloat
    var lineSpacing: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = arrange(width: proposal.width ?? .infinity, subviews: subviews)
        let width = rows.map(\.width).max() ?? 0
        let height = rows.map(\.height).reduce(0, +) + lineSpacing * CGFloat(max(rows.count - 1, 0))
        return CGSize(width: proposal.width ?? width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var y = bounds.minY
        for row in arrange(width: bounds.width, subviews: subviews) {
            var x = bounds.minX
            for index in row.indices {
                let size = subviews[index].sizeThatFits(.unspecified)
                subviews[index].place(
                    at: CGPoint(x: x, y: y + (row.height - size.height) / 2),
                    proposal: ProposedViewSize(size)
                )
                x += size.width + spacing
            }
            y += row.height + lineSpacing
        }
    }

    private struct Row {
        var indices: [Int] = []
        var width: CGFloat = 0
        var height: CGFloat = 0
    }

    private func arrange(width: CGFloat, subviews: Subviews) -> [Row] {
        var rows: [Row] = [Row()]
        for index in subviews.indices {
            let size = subviews[index].sizeThatFits(.unspecified)
            // Zero-size views (a hidden effort picker) take no slot.
            guard size.width > 0 else { continue }
            let needed = rows[rows.count - 1].indices.isEmpty ? size.width : rows[rows.count - 1].width + spacing + size.width
            if needed > width, !rows[rows.count - 1].indices.isEmpty {
                rows.append(Row())
            }
            var row = rows[rows.count - 1]
            row.width = row.indices.isEmpty ? size.width : row.width + spacing + size.width
            row.height = max(row.height, size.height)
            row.indices.append(index)
            rows[rows.count - 1] = row
        }
        return rows
    }
}

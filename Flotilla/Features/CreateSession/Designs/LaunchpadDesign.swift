import SwiftUI
import SessionKit
import AgentKit
import DesignSystem

/// The home dashboard's always-visible session composer.
///
/// Started life as one of four candidate modal designs ("Launchpad") — big
/// agent cards, a project grid, a heavy footer — chosen for the home screen
/// because that context is ambient and browsable, unlike the New Session
/// window's keyboard-driven interruption (`CommandBarDesign`). Rebuilt here as
/// an inline card rather than a modal: no `ScrollView` of its own (the
/// dashboard already scrolls), no `.ignoresSafeArea()` backdrop (the dashboard
/// paints its own), no footer bar — launch controls live at the foot of the
/// card instead.
///
/// This is a deliberately colourful design relative to the rest of the app —
/// see `.impeccable.md`'s "avoid floating-card dashboards and decorative
/// gradients" guidance — kept because it reads as the front door to the whole
/// product, not a utility form. Every colour is still a `FlotillaColors`
/// token, so it adapts to light and dark like the rest.
struct LaunchpadDesign: View {
    @Bindable var draft: SessionDraft
    @Bindable var store: AppStore
    let onLaunch: (UUID) -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var hoveredAgent: AgentKind?
    @State private var hoveredChoice: ProjectChoice?
    @State private var projectQuery = ""
    @State private var showAllProjects = false
    @FocusState private var goalFocused: Bool
    @State private var antigravityCoordinator = AntigravityModelEffortCoordinator()

    /// Tiles beyond this many are hidden behind "Show more" — the known-project
    /// list only grows, and an unbounded grid on a page that already scrolls
    /// would eventually push the rest of the dashboard off screen.
    private static let restingProjectLimit = 5

    /// The agent-tinted wash the original modal version of this design had —
    /// brought back for the home composer at the user's request. Unlike the
    /// modal, this doesn't `.ignoresSafeArea()`: it's inline content now, and
    /// `HomeDashboardView`'s own `.glassEffect` card clips it to the card's
    /// rounded shape. It also fades to `.clear` rather than an opaque canvas
    /// fill, so the true Liquid Glass material behind it keeps showing
    /// through — the old modal had no glass of its own to preserve.
    ///
    /// Antigravity's brand mark is a gradient, but its wash here is the flat
    /// `AgentBrand.antigravityBackground` blue, so all four agents share one
    /// corner-tint treatment.
    private var washColor: Color {
        draft.agent == .antigravity
            ? AgentBrand.antigravityBackground
            : AgentBrand.accentColor(for: draft.agent)
    }

    private var backdrop: some View {
        LinearGradient(
            colors: [washColor.opacity(0.16), washColor.opacity(0.05), .clear],
            startPoint: .topLeading,
            endPoint: .center
        )
        .animation(reduceMotion ? nil : FlotillaMotion.slow.curve, value: draft.agent)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: FlotillaSpacing.large) {
            section(title: "Agent", trailing: { modelControls }) { agentCards }
            section(title: "Workspace", trailing: { chooseFolderLink }) { workspaceContent }
            section(title: "Objective", trailing: { EmptyView() }) { goalCard }

            if let error = store.lastCreationError {
                FlotillaBanner.error(error) { store.lastCreationError = nil }
            }

            controlRow
        }
        // Padding lives here, inside the tinted+clipped background, rather
        // than at the `HomeDashboardView` call site — added outside instead,
        // it would leave a band of unpainted, unrounded space between the
        // tint's edge and the glass card's actual (rounded) edge.
        .padding(FlotillaSpacing.large)
        .background { backdrop }
        .clipShape(RoundedRectangle(cornerRadius: FlotillaRadius.modal, style: .continuous))
        .onChange(of: draft.projectChoice) { _, _ in
            // A pick from the tiles is a decision, not a search — the filter
            // that helped find it would otherwise linger and hide the rest of
            // the (now newly relevant) list on the next look.
            projectQuery = ""
        }
        .onChange(of: draft.goal) { _, _ in draft.syncModeFromGoal() }
        .task(id: draft.agent) { await antigravityCoordinator.refresh() }
    }

    private func section<Trailing: View, Content: View>(
        title: String,
        @ViewBuilder trailing: () -> Trailing,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: FlotillaSpacing.medium) {
            HStack {
                Text(title.uppercased())
                    .font(FlotillaTypography.caption2.weight(.bold))
                    .tracking(FlotillaTypography.Tracking.loose3)
                    .foregroundStyle(FlotillaColors.textTertiary)
                Spacer()
                trailing()
            }
            content()
        }
    }

    // MARK: - Agents

    private var agentCards: some View {
        HStack(spacing: FlotillaSpacing.medium) {
            ForEach(AgentKind.allCases) { kind in
                agentCard(kind)
            }
        }
    }

    private func agentCard(_ kind: AgentKind) -> some View {
        let isActive = kind == draft.agent
        let isHovered = hoveredAgent == kind
        return Button {
            draft.selectAgent(kind)
        } label: {
            HStack(spacing: FlotillaSpacing.small) {
                ProviderLogo(agent: kind)
                    .frame(width: FlotillaIconSize.large, height: FlotillaIconSize.large)

                Text(kind.displayName)
                    .font(FlotillaTypography.callout.weight(.semibold))
                    .foregroundStyle(FlotillaColors.textPrimary)
                    .lineLimit(1)

                Spacer(minLength: 0)

                if isActive {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: FlotillaIconSize.small))
                        .foregroundStyle(AgentBrand.accentColor(for: kind))
                }
            }
            .padding(.horizontal, FlotillaSpacing.medium)
            .padding(.vertical, FlotillaSpacing.medium)
            .frame(maxWidth: .infinity)
            .background(
                isActive ? AgentBrand.accentColor(for: kind).opacity(FlotillaStateOpacity.selected) : FlotillaColors.surface,
                in: RoundedRectangle(cornerRadius: FlotillaRadius.panel, style: .continuous)
            )
            .overlay {
                RoundedRectangle(cornerRadius: FlotillaRadius.panel, style: .continuous)
                    .strokeBorder(
                        isActive ? AgentBrand.accentColor(for: kind) : FlotillaColors.separator,
                        // Selection is carried by the border weight and the
                        // checkmark too, so it never rests on hue alone.
                        lineWidth: isActive ? FlotillaBorderWidth.medium : FlotillaBorderWidth.hairline
                    )
            }
            .flotillaShadow(isActive ? .level2 : .level1)
            .scaleEffect(isHovered && !reduceMotion ? 1.025 : 1)
        }
        .buttonStyle(.plain)
        .onHover { hoveredAgent = $0 ? kind : nil }
        .withFlotillaMotion(.fast, value: isHovered)
        .withFlotillaMotion(.fast, value: isActive)
        .accessibilityIdentifier("Home.Agent.\(kind.rawValue)")
        .accessibilityAddTraits(isActive ? [.isSelected] : [])
    }

    private var modelControls: some View {
        HStack(spacing: FlotillaSpacing.small) {
            ModelPickerView(
                agent: draft.agent,
                openCodeSubscription: draft.openCodeSubscription,
                model: $draft.model,
                effort: antigravityCoordinator.currentEffort(for: draft)
            )
            .controlSize(.small)
            .frame(maxWidth: 180)
            .accessibilityIdentifier("Home.ModelField")
            if antigravityCoordinator.supportsEffort(for: draft) {
                EffortLevelPicker(
                    agent: draft.agent,
                    model: draft.model,
                    effort: antigravityCoordinator.effortBinding(for: draft),
                    accessibilityIdentifier: "Home.EffortPicker"
                )
            }
        }
    }

    // MARK: - Workspace

    @ViewBuilder
    private var workspaceContent: some View {
        VStack(alignment: .leading, spacing: FlotillaSpacing.small) {
            if draft.choices.count > 4 {
                HStack(spacing: FlotillaSpacing.small) {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: FlotillaIconSize.small))
                        .foregroundStyle(FlotillaColors.textTertiary)
                    TextField("Filter projects…", text: $projectQuery)
                        .textFieldStyle(.plain)
                        .font(FlotillaTypography.callout)
                        .accessibilityIdentifier("Home.ProjectFilter")
                }
                .padding(.horizontal, FlotillaSpacing.medium)
                .padding(.vertical, FlotillaSpacing.small)
                .background(FlotillaColors.surface, in: RoundedRectangle(cornerRadius: FlotillaRadius.control, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: FlotillaRadius.control, style: .continuous)
                        .strokeBorder(FlotillaColors.separator, lineWidth: FlotillaBorderWidth.hairline)
                }
            }

            projectTiles

            if hiddenProjectCount > 0 {
                Button {
                    withAnimation(reduceMotion ? nil : FlotillaMotion.snappy.curve) {
                        showAllProjects = true
                    }
                } label: {
                    Text("Show \(hiddenProjectCount) more")
                        .font(FlotillaTypography.caption2.weight(.medium))
                }
                .buttonStyle(.link)
            }
        }
    }

    private var visibleChoices: [ProjectChoice] {
        showAllProjects
            ? draft.filteredChoices(query: projectQuery)
            : draft.filteredChoices(query: projectQuery, restingLimit: Self.restingProjectLimit)
    }

    private var hiddenProjectCount: Int {
        showAllProjects || !projectQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? 0
            : draft.hiddenChoiceCount(restingLimit: Self.restingProjectLimit)
    }

    private var projectTiles: some View {
        LazyVGrid(
            columns: [GridItem(.adaptive(minimum: 168), spacing: FlotillaSpacing.medium)],
            spacing: FlotillaSpacing.medium
        ) {
            ForEach(visibleChoices) { choice in
                projectTile(choice)
            }
        }
    }

    private func projectTile(_ choice: ProjectChoice) -> some View {
        let isActive = choice == draft.projectChoice
        let isHovered = hoveredChoice == choice
        return Button {
            draft.projectChoice = choice
        } label: {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: FlotillaSpacing.xSmall) {
                    Image(systemName: choice.symbolName)
                        .font(.system(size: FlotillaIconSize.small))
                        .foregroundStyle(isActive ? FlotillaColors.accent : FlotillaColors.textTertiary)
                    Text(choice.displayName)
                        .font(FlotillaTypography.callout.weight(.medium))
                        .foregroundStyle(FlotillaColors.textPrimary)
                        .lineLimit(1)
                    Spacer(minLength: 0)
                    if isActive {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: FlotillaIconSize.small))
                            .foregroundStyle(FlotillaColors.accent)
                    }
                }

                // Paths truncate from the head (the tail identifies the repo);
                // the general-session caption is prose and truncates normally.
                if let path = choice.displayPath {
                    MarqueeText(
                        path,
                        font: .system(size: 10, design: .monospaced),
                        color: FlotillaColors.textTertiary,
                        isHovered: isHovered,
                        truncationMode: .head
                    )
                } else {
                    Text("No repository — a scratch directory")
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(FlotillaColors.textTertiary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, FlotillaSpacing.medium)
            .padding(.vertical, FlotillaSpacing.small)
            .background(
                isActive ? FlotillaColors.accent.opacity(FlotillaStateOpacity.hover) : FlotillaColors.surface,
                in: RoundedRectangle(cornerRadius: FlotillaRadius.card, style: .continuous)
            )
            .overlay {
                RoundedRectangle(cornerRadius: FlotillaRadius.card, style: .continuous)
                    .strokeBorder(
                        isActive ? FlotillaColors.accent : FlotillaColors.separator,
                        lineWidth: isActive ? FlotillaBorderWidth.thin : FlotillaBorderWidth.hairline
                    )
            }
            .flotillaShadow(.level1)
            .scaleEffect(isHovered && !reduceMotion ? 1.02 : 1)
        }
        .buttonStyle(.plain)
        .onHover { hoveredChoice = $0 ? choice : nil }
        .withFlotillaMotion(.fast, value: isHovered)
        .accessibilityIdentifier(
            choice.isGeneral ? "Home.Source.General" : "Home.Project-\(choice.displayName)"
        )
        .accessibilityAddTraits(isActive ? [.isSelected] : [])
    }

    private var chooseFolderLink: some View {
        Button {
            draft.chooseFolderFromPanel()
        } label: {
            Label("Choose folder…", systemImage: "folder.badge.plus")
                .font(FlotillaTypography.caption2)
        }
        .buttonStyle(.link)
        .accessibilityIdentifier("Home.ChooseFolderButton")
    }

    // MARK: - Goal

    private var goalCard: some View {
        VStack(alignment: .leading, spacing: FlotillaSpacing.small) {
            ZStack(alignment: .topLeading) {
                TextEditor(text: $draft.goal)
                    .font(.system(size: 14))
                    .scrollContentBackground(.hidden)
                    .padding(FlotillaSpacing.small)
                    .frame(minHeight: 60)
                    .focused($goalFocused)
                    .accessibilityIdentifier(AXID.homeGoalField.rawValue)
                if draft.goal.isEmpty {
                    Text("Describe the outcome, the constraints, and what “done” means…")
                        .font(.system(size: 14))
                        .foregroundStyle(FlotillaColors.textTertiary)
                        .padding(.horizontal, FlotillaSpacing.medium)
                        .padding(.vertical, FlotillaSpacing.medium + 1)
                        .allowsHitTesting(false)
                }
            }
            .background(FlotillaColors.surface)
            .clipShape(RoundedRectangle(cornerRadius: FlotillaRadius.card, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: FlotillaRadius.card, style: .continuous)
                    .strokeBorder(FlotillaColors.separator, lineWidth: FlotillaBorderWidth.hairline)
            }

            settingsRow
        }
    }

    private var settingsRow: some View {
        HStack(spacing: FlotillaSpacing.small) {
            SessionModeToggle(mode: $draft.initialMode, accessibilityIdentifier: "Home.ModePicker")

            if draft.supportsWorktree { isolationSwitch }
        }
    }

    private var isolationSwitch: some View {
        HStack(spacing: FlotillaSpacing.small) {
            isolationPill(
                title: "New Worktree",
                symbol: "arrow.triangle.branch",
                isActive: draft.createWorktree,
                identifier: "Home.Checkout.Worktree"
            ) { draft.createWorktree = true }

            isolationPill(
                title: "Main Checkout",
                symbol: "shippingbox",
                isActive: !draft.createWorktree,
                identifier: "Home.Checkout.Main"
            ) { draft.createWorktree = false }

            Spacer(minLength: 0)

            if let warning = draft.preview.sharedCheckoutWarning {
                Label(warning, systemImage: "exclamationmark.triangle.fill")
                    .font(FlotillaTypography.caption3)
                    .foregroundStyle(FlotillaColors.warning)
                    .lineLimit(1)
            }
        }
    }

    private func isolationPill(
        title: String,
        symbol: String,
        isActive: Bool,
        identifier: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Label {
                Text(title)
            } icon: {
                if symbol == "arrow.triangle.branch" {
                    GitBranchIcon(size: FlotillaIconSize.xSmall)
                } else {
                    Image(systemName: symbol)
                }
            }
            .font(FlotillaTypography.caption2.weight(.medium))
                .foregroundStyle(isActive ? FlotillaColors.accentContent : FlotillaColors.textSecondary)
                .padding(.horizontal, FlotillaSpacing.medium)
                .padding(.vertical, FlotillaSpacing.small)
                .background(
                    isActive ? FlotillaColors.accent : FlotillaColors.surface,
                    in: Capsule()
                )
                .overlay(
                    Capsule().strokeBorder(
                        isActive ? .clear : FlotillaColors.separator,
                        lineWidth: FlotillaBorderWidth.hairline
                    )
                )
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier(identifier)
        .accessibilityAddTraits(isActive ? [.isSelected] : [])
    }

    // MARK: - Controls

    /// `ViewThatFits` rather than a fixed `HStack`: this card lives at the top
    /// of a resizable window, and the summary text needs a narrow fallback
    /// rather than clipping under the buttons.
    private var controlRow: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: FlotillaSpacing.medium) {
                summary
                Spacer(minLength: FlotillaSpacing.medium)
                trailingControls
            }

            VStack(alignment: .leading, spacing: FlotillaSpacing.small) {
                summary
                HStack(spacing: FlotillaSpacing.small) {
                    Spacer(minLength: 0)
                    trailingControls
                }
            }
        }
    }

    private var summary: some View {
        let preview = draft.preview
        return HStack(spacing: FlotillaSpacing.small) {
            if let branch = preview.displayBranch {
                GitBranchLabel(branch, size: 10)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(FlotillaColors.statusWorking)
                    .padding(.horizontal, FlotillaSpacing.small)
                    .padding(.vertical, 2)
                    .background(FlotillaColors.successSurface, in: Capsule())
            }
            Text(preview.displayDirectory)
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(FlotillaColors.textTertiary)
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("Home.LaunchSummary")
    }

    private var trailingControls: some View {
        HStack(spacing: FlotillaSpacing.small) {
            if draft.isCreating {
                ProgressView()
                    .controlSize(.small)
                    .accessibilityIdentifier("Home.ProgressIndicator")
            }

            // Both outcomes name what you are looking at afterwards.
            // "Background" described the process rather than the result, and
            // its recessive styling nudged toward the single-session habit the
            // product exists to move past — so the two now carry the same
            // weight and differ only in tint.
            Button("Launch & Stay Here") { launch(opensSession: false) }
                .buttonStyle(.bordered)
                .controlSize(.large)
                .disabled(!draft.canLaunch)
                .keyboardShortcut(.return, modifiers: [.command, .shift])
                .accessibilityIdentifier("Home.BackgroundButton")

            Button {
                launch(opensSession: true)
            } label: {
                Label("Launch & Open", systemImage: "play.fill")
                    .font(FlotillaTypography.callout.weight(.semibold))
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .tint(FlotillaColors.accent)
            .disabled(!draft.canLaunch)
            .keyboardShortcut(.return, modifiers: .command)
            .accessibilityIdentifier(AXID.homeLaunchButton.rawValue)
        }
    }

    private func launch(opensSession: Bool) {
        Task {
            store.lastCreationError = nil
            guard let id = await draft.launch(opensSession: opensSession) else { return }
            draft.clearGoal()
            if opensSession { onLaunch(id) }
        }
    }
}

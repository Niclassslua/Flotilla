import SwiftUI
import SessionKit
import DesignSystem
import SettingsKit

enum SessionLaunchFormDensity {
    case sheet
    case hero
    case inline
    /// Editor + control row with no title, material, shadow, or border. The
    /// host supplies every bit of container chrome, so the home screen can wrap
    /// the composer in its own glass card without double-stacking elevation the
    /// way `.hero` would.
    case chromeless
}

struct SessionLaunchForm: View {
    let store: AppStore
    let settings: AppSettings
    let defaultAgent: AgentKind
    let initialProject: Project?
    let openCodeSubscription: OpenCodeSubscription
    let density: SessionLaunchFormDensity
    let onLaunch: (UUID) -> Void
    let onCancel: () -> Void

    @State private var goal = ""
    @State private var selectedProject: Project?
    @State private var agent: AgentKind
    @State private var model = ""
    @State private var effort: AgentEffort = .medium
    @State private var useWorktree = true
    @State private var isLaunching = false
    @State private var openCodeSubscriptionState: OpenCodeSubscription

    init(
        store: AppStore,
        settings: AppSettings,
        defaultAgent: AgentKind,
        initialProject: Project?,
        openCodeSubscription: OpenCodeSubscription,
        density: SessionLaunchFormDensity = .sheet,
        onLaunch: @escaping (UUID) -> Void,
        onCancel: @escaping () -> Void
    ) {
        self.store = store
        self.settings = settings
        self.defaultAgent = defaultAgent
        self.initialProject = initialProject
        self.openCodeSubscription = openCodeSubscription
        self.density = density
        self.onLaunch = onLaunch
        self.onCancel = onCancel

        _agent = State(initialValue: defaultAgent)
        _selectedProject = State(initialValue: initialProject)
        _openCodeSubscriptionState = State(initialValue: openCodeSubscription)
    }

    private var canLaunch: Bool {
        !goal.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !isLaunching
    }

    private var projectOptions: [Project] {
        [Project(id: UUID(uuidString: "00000000-0000-0000-0000-000000000000")!, name: "General", rootPath: URL(fileURLWithPath: "/"))] + store.projects
    }

    var body: some View {
        Group {
            switch density {
            case .sheet:
                sheetContent
            case .hero:
                heroContent
            case .inline:
                inlineContent
            case .chromeless:
                chromelessContent
            }
        }
        .onChange(of: agent) { _, newAgent in
            if newAgent != .openCode {
                openCodeSubscriptionState = .none
            }
        }
    }

    @ViewBuilder
    private var sheetContent: some View {
        VStack(spacing: 0) {
            ZStack(alignment: .topLeading) {
                TextEditor(text: $goal)
                    .font(.title3)
                    .scrollContentBackground(.hidden)
                    .padding(14)
                    .frame(minHeight: 108)
                    .accessibilityIdentifier("CreateSession.GoalField")
                if goal.isEmpty {
                    Text("Describe an outcome, a bug, or a question…")
                        .font(.title3)
                        .foregroundStyle(.tertiary)
                        .padding(.horizontal, 19)
                        .padding(.vertical, 21)
                        .allowsHitTesting(false)
                }
            }

            Divider()

            if let error = store.lastCreationError {
                FlotillaBanner.error(error) {
                    store.lastCreationError = nil
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
            }

            HStack(spacing: 10) {
                projectPicker
                agentPicker
                modelPicker
                effortPicker
                worktreeToggle

                Spacer()

                if isLaunching { ProgressView().controlSize(.small) }
                launchButton
            }
            .padding(12)
        }
        .background(.regularMaterial)
        .compositingGroup()
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(FlotillaColors.separator)
        }
        .shadow(color: .black.opacity(0.08), radius: 22, y: 10)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    @ViewBuilder
    private var heroContent: some View {
        VStack(spacing: 16) {
            Text("Start something new")
                .font(.title2.weight(.semibold))

            ZStack(alignment: .topLeading) {
                TextEditor(text: $goal)
                    .font(.title3)
                    .scrollContentBackground(.hidden)
                    .padding(14)
                    .frame(minHeight: 108)
                    .accessibilityIdentifier("Home.GoalField")
                if goal.isEmpty {
                    Text("Describe an outcome, a bug, or a question…")
                        .font(.title3)
                        .foregroundStyle(.tertiary)
                        .padding(.horizontal, 19)
                        .padding(.vertical, 21)
                        .allowsHitTesting(false)
                }
            }
            .background(.regularMaterial)
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .overlay { RoundedRectangle(cornerRadius: 10).strokeBorder(FlotillaColors.separator) }

            if let error = store.lastCreationError {
                FlotillaBanner.error(error) {
                    store.lastCreationError = nil
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
            }

            HStack(spacing: 10) {
                projectPicker
                agentPicker
                modelPicker
                effortPicker

                if selectedProject != nil {
                    worktreeToggle
                }

                Spacer()

                if isLaunching { ProgressView().controlSize(.small) }
                launchButton
            }
            .padding(12)
        }
        .padding(18)
        .background(.regularMaterial)
        .compositingGroup()
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(FlotillaColors.separator)
        }
        .shadow(color: .black.opacity(0.08), radius: 22, y: 10)
    }

    @ViewBuilder
    private var chromelessContent: some View {
        VStack(spacing: FlotillaSpacing.medium) {
            ZStack(alignment: .topLeading) {
                TextEditor(text: $goal)
                    .font(.title3)
                    .scrollContentBackground(.hidden)
                    .padding(FlotillaSpacing.medium)
                    // Bounded on both ends: the host layouts place this in a
                    // non-scrolling region, where an unbounded TextEditor
                    // expands to fill the whole window.
                    .frame(minHeight: 96, maxHeight: 150)
                    .accessibilityIdentifier(AXID.homeGoalField.rawValue)
                if goal.isEmpty {
                    Text("Describe an outcome, a bug, or a question…")
                        .font(.title3)
                        .foregroundStyle(.tertiary)
                        .padding(.horizontal, 17)
                        .padding(.vertical, 19)
                        .allowsHitTesting(false)
                }
            }

            if let error = store.lastCreationError {
                FlotillaBanner.error(error) {
                    store.lastCreationError = nil
                }
            }

            // The composer is hosted at widths from a full content column down
            // to a narrow one, so the control row falls back to two lines
            // rather than clipping.
            ViewThatFits(in: .horizontal) {
                HStack(spacing: FlotillaSpacing.small) {
                    chromelessPickers
                    Spacer(minLength: FlotillaSpacing.small)
                    chromelessTrailing
                }

                VStack(spacing: FlotillaSpacing.small) {
                    HStack(spacing: FlotillaSpacing.small) {
                        chromelessPickers
                        Spacer(minLength: 0)
                    }
                    HStack(spacing: FlotillaSpacing.small) {
                        Spacer(minLength: 0)
                        chromelessTrailing
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var chromelessPickers: some View {
        projectPicker
        agentPicker
        modelPicker
        effortPicker
        if selectedProject != nil {
            worktreeToggle
        }
    }

    @ViewBuilder
    private var chromelessTrailing: some View {
        if isLaunching { ProgressView().controlSize(.small) }
        launchButton
    }

    @ViewBuilder
    private var inlineContent: some View {
        VStack(spacing: 12) {
            ZStack(alignment: .topLeading) {
                TextEditor(text: $goal)
                    .font(.body)
                    .scrollContentBackground(.hidden)
                    .padding(10)
                    .frame(minHeight: 88)
                    .accessibilityIdentifier("CreateSession.GoalField")
                if goal.isEmpty {
                    Text("Describe an outcome, a bug, or a question…")
                        .font(.body)
                        .foregroundStyle(.tertiary)
                        .padding(.horizontal, 15)
                        .padding(.vertical, 17)
                        .allowsHitTesting(false)
                }
            }
            .background(Color(nsColor: .textBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .overlay { RoundedRectangle(cornerRadius: 10).strokeBorder(FlotillaColors.separator) }

            if let error = store.lastCreationError {
                FlotillaBanner.error(error) {
                    store.lastCreationError = nil
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
            }

            HStack(spacing: 10) {
                projectPicker
                agentPicker
                modelPicker
                effortPicker

                if selectedProject != nil {
                    worktreeToggle
                }

                Spacer()

                if isLaunching { ProgressView().controlSize(.small) }
                launchButton
            }
            .padding(12)
        }
        .background(FlotillaColors.surface, in: RoundedRectangle(cornerRadius: 14))
        .overlay {
            RoundedRectangle(cornerRadius: 14)
                .strokeBorder(FlotillaColors.separator)
        }
    }

    private var projectPicker: some View {
        Menu {
            Button {
                selectedProject = nil
            } label: {
                Label("General session", systemImage: "sparkles")
            }
            Divider()
            ForEach(store.projects) { project in
                Button(project.name) { selectedProject = project }
            }
        } label: {
            Label(selectedProject?.name ?? "General", systemImage: selectedProject == nil ? "sparkles" : "folder")
        }
        .frame(minWidth: 140)
        .help("Choose project context")
        .accessibilityIdentifier("CreateSession.ProjectPicker")
    }

    private var agentPicker: some View {
        Picker("Agent", selection: $agent) {
            ForEach(AgentKind.allCases) { kind in
                Text(kind.displayName).tag(kind)
            }
        }
        .labelsHidden()
        .frame(width: 126)
        .accessibilityIdentifier("CreateSession.AgentPicker")
    }

    private var modelPicker: some View {
        ModelPickerView(agent: agent, openCodeSubscription: openCodeSubscription, model: $model)
            .accessibilityIdentifier("CreateSession.ModelPicker")
    }

    private var effortPicker: some View {
        EffortLevelPicker(agent: agent, model: model, effort: $effort)
            .accessibilityIdentifier("CreateSession.EffortPicker")
    }

    private var worktreeToggle: some View {
        Toggle(isOn: $useWorktree) {
            Label("Worktree", systemImage: "arrow.triangle.branch")
        }
        .toggleStyle(.button)
        .help("Launch in a new isolated worktree")
        .frame(width: 126)
        .accessibilityIdentifier("CreateSession.WorktreeToggle")
    }

    private var launchButton: some View {
        Button("Start Session", action: launch)
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(!canLaunch)
            .keyboardShortcut(.return, modifiers: [.command])
            .accessibilityIdentifier("CreateSession.LaunchButton")
    }

    private func launch() {
        let trimmedGoal = goal.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedGoal.isEmpty else { return }
        isLaunching = true
        let previousIDs = Set(store.sessions.map(\.id))
        Task {
            await store.createSession(
                title: String(trimmedGoal.prefix(60)),
                goal: trimmedGoal,
                agent: agent,
                model: model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : model,
                effort: agent.supportsEffortSelection ? effort : nil,
                projectFolder: selectedProject?.rootPath,
                checkoutMode: useWorktree && selectedProject != nil ? .newWorktree : .mainCheckout,
                fetchBeforeCreatingWorktree: settings.git.fetchBeforeCreatingWorktree
            )
            isLaunching = false
            if store.lastCreationError == nil,
               let created = store.sessions.first(where: { !previousIDs.contains($0.id) }) {
                goal = ""
                onLaunch(created.id)
            } else {
                onCancel()
            }
        }
    }
}
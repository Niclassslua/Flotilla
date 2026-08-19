import SwiftUI
import AppKit
import SessionKit
import AgentKit
import DesignSystem
import SettingsKit

struct CreateSessionView: View {
    @Bindable var store: AppStore
    @Environment(\.dismiss) private var dismiss

    let createWorktreeByDefault: Bool
    let fetchBeforeCreatingWorktree: Bool
    let initialProject: Project?
    let didCreateSession: (UUID) -> Void

    @State private var isGeneralSession = true
    @State private var selectedFolder: URL?
    @State private var goal = ""
    @State private var agent: AgentKind
    @State private var model = ""
    @State private var effort: AgentEffort = .medium
    @State private var createWorktree: Bool = true
    @State private var isCreating = false
    @State private var openCodeSubscription: OpenCodeSubscription = .none

    init(
        store: AppStore,
        createWorktreeByDefault: Bool = true,
        fetchBeforeCreatingWorktree: Bool = false,
        initialProject: Project? = nil,
        didCreateSession: @escaping (UUID) -> Void = { _ in },
        openCodeSubscription: OpenCodeSubscription = .none,
        defaultAgent: AgentKind = .claudeCode
    ) {
        self.store = store
        self.createWorktreeByDefault = createWorktreeByDefault
        self.fetchBeforeCreatingWorktree = fetchBeforeCreatingWorktree
        self.initialProject = initialProject
        self.didCreateSession = didCreateSession
        _isGeneralSession = State(initialValue: initialProject == nil)
        _selectedFolder = State(initialValue: initialProject?.rootPath)
        _createWorktree = State(initialValue: createWorktreeByDefault)
        _openCodeSubscription = State(initialValue: openCodeSubscription)
        _agent = State(initialValue: defaultAgent)
    }

    private var checkoutMode: CheckoutMode {
        createWorktree ? .newWorktree : .mainCheckout
    }

    private var isUITesting: Bool {
        ProcessInfo.processInfo.environment["UI_TESTING"] == "1"
    }

    private var canCreate: Bool {
        (isGeneralSession || selectedFolder != nil) && !isCreating
    }

    private var trimmedModel: String? {
        let trimmed = model.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: FlotillaSpacing.large) {
                    sourceSection
                    goalSection
                    agentSection
                    if !isGeneralSession { checkoutSection }

if let error = store.lastCreationError {
                    FlotillaBanner.error(error) {
                        store.lastCreationError = nil
                    }
                }
                }
                .padding(FlotillaSpacing.xLarge)
            }
            Divider()
            footer
        }
        .frame(minWidth: 560, idealWidth: 640, minHeight: 720, idealHeight: 780)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private var header: some View {
        HStack(spacing: 14) {
            ZStack {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(FlotillaColors.accent)
                Image(systemName: "point.3.connected.trianglepath.dotted")
                    .font(.system(size: 24, weight: .semibold))
                    .foregroundStyle(.white)
            }
            .frame(width: 48, height: 48)
            .shadow(color: FlotillaColors.accent.opacity(0.25), radius: 10, y: 4)

            VStack(alignment: .leading, spacing: 3) {
                Text("Launch a Session")
                    .font(.title2.weight(.semibold))
                Text("Give one agent a clear objective and an isolated place to work.")
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(.horizontal, FlotillaSpacing.xLarge)
        .padding(.vertical, 18)
        .background(.thinMaterial)
    }

    private var sourceSection: some View {
        CreationSection(number: "01", title: "Choose the workspace", subtitle: "Start anywhere, or attach the session to a repository.") {
            Picker("Session Type", selection: $isGeneralSession) {
                Label("General Session", systemImage: "sparkles").tag(true)
                Label("Project Folder", systemImage: "folder").tag(false)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .controlSize(.large)
            .accessibilityIdentifier("CreateSession.SourcePicker")

            if !isGeneralSession {
                HStack(spacing: 10) {
                    Image(systemName: selectedFolder == nil ? "folder.badge.questionmark" : "folder.fill")
                        .foregroundStyle(selectedFolder == nil ? Color.secondary : FlotillaColors.accent)
                    Text(selectedFolder?.path ?? "No project folder selected")
                        .foregroundStyle(selectedFolder == nil ? .secondary : .primary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .accessibilityIdentifier("CreateSession.SelectedFolderLabel")
                    Button("Choose…") { chooseFolder() }
                        .accessibilityIdentifier("CreateSession.ChooseFolderButton")
                }
                .padding(10)
                .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
            }
        }
    }

    private var goalSection: some View {
        CreationSection(number: "02", title: "Set the objective", subtitle: "Optional — passed directly to the selected CLI on launch.") {
            ZStack(alignment: .topLeading) {
                TextEditor(text: $goal)
                    .font(.body)
                    .scrollContentBackground(.hidden)
                    .padding(8)
                    .frame(minHeight: 84, idealHeight: 96, maxHeight: 128)
                    .accessibilityIdentifier("CreateSession.GoalField")
                if goal.isEmpty {
                    Text("Describe the outcome, constraints, and what ‘done’ means…")
                        .foregroundStyle(.tertiary)
                        .padding(.horizontal, 13)
                        .padding(.vertical, 16)
                        .allowsHitTesting(false)
                }
            }
            .background(Color(nsColor: .textBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(Color(nsColor: .separatorColor))
            }
        }
    }

    private var agentSection: some View {
        CreationSection(number: "03", title: "Select the agent", subtitle: "Your existing CLI authentication is used unchanged.") {
            Picker("Agent", selection: $agent) {
                ForEach(AgentKind.allCases) { kind in
                    Label(kind.displayName, image: kind.logoImageName).tag(kind)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .controlSize(.large)
            .accessibilityIdentifier("CreateSession.AgentPicker")

            HStack(spacing: 8) {
                ProviderLogo(agent: agent)
                    .frame(width: 16, height: 16)
                Text(agentDescription)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Text("Credentials stay in the CLI")
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(.secondary)
            }

            HStack(spacing: 8) {
                ModelPickerView(agent: agent, openCodeSubscription: openCodeSubscription, model: $model)
                    .accessibilityIdentifier("CreateSession.ModelField")

                EffortLevelPicker(
                    agent: agent,
                    model: model,
                    effort: $effort,
                    accessibilityIdentifier: "CreateSession.EffortPicker"
                )
            }
        }
    }

    private var checkoutSection: some View {
        CreationSection(number: "04", title: "Choose isolation", subtitle: "A worktree keeps this agent’s edits separate from your main checkout.") {
            Picker("Isolation", selection: $createWorktree) {
                Label("Main Checkout", systemImage: "shippingbox").tag(false)
                Label("New Worktree", systemImage: "arrow.triangle.branch").tag(true)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .controlSize(.large)
            .accessibilityIdentifier("CreateSession.CheckoutPicker")

            HStack(spacing: 8) {
                Image(systemName: createWorktree ? "checkmark.shield.fill" : "exclamationmark.triangle")
                    .foregroundStyle(createWorktree ? FlotillaColors.accent : Color.secondary)
                Text(createWorktree
                     ? "Creates a dedicated branch and worktree under your configured base directory."
                     : "The agent edits the selected checkout directly; concurrent sessions can conflict.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("CreateSession.CheckoutDescription")
            }
            .animation(.easeInOut(duration: 0.16), value: createWorktree)
        }
    }

    private var footer: some View {
        HStack(spacing: 10) {
            Button("Cancel") { dismiss() }
                .keyboardShortcut(.cancelAction)
                .accessibilityIdentifier("CreateSession.CancelButton")
            Spacer()
            if isCreating {
                ProgressView()
                    .controlSize(.small)
                    .accessibilityIdentifier("CreateSession.ProgressIndicator")
            }
            Button("Background") {
                launch(opensSession: false)
            }
            .disabled(!canCreate)
            .accessibilityIdentifier("CreateSession.BackgroundButton")
            Button("Launch Session") {
                launch(opensSession: true)
            }
            .buttonStyle(.borderedProminent)
            .keyboardShortcut(.defaultAction)
            .disabled(!canCreate)
            .accessibilityIdentifier("CreateSession.CreateButton")
        }
        .padding(.horizontal, FlotillaSpacing.xLarge)
        .padding(.vertical, 14)
        .background(.thinMaterial)
    }

    private var sessionTitle: String {
        let trimmedGoal = goal.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedGoal.isEmpty {
            return String(trimmedGoal.prefix(60))
        }
        return isGeneralSession ? "General session" : (selectedFolder?.lastPathComponent ?? "New session")
    }

    private func launch(opensSession: Bool) {
        Task {
            isCreating = true
            await store.createSession(
                title: sessionTitle,
                goal: goal,
                agent: agent,
                model: trimmedModel,
                effort: agent.supportsEffortSelection ? effort : nil,
                projectFolder: isGeneralSession ? nil : selectedFolder,
                checkoutMode: checkoutMode,
                deliverGoal: !goal.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                fetchBeforeCreatingWorktree: fetchBeforeCreatingWorktree
            )
            isCreating = false
            guard store.lastCreationError == nil else { return }
            if opensSession, let id = store.selectedSessionID { didCreateSession(id) }
            dismiss()
        }
    }

    private var agentDescription: String {
        switch agent {
        case .claudeCode: "Claude Code in an interactive terminal"
        case .codexCLI: "Codex CLI in an interactive terminal"
        case .openCode: "OpenCode in an interactive terminal"
        case .antigravity: "Antigravity in an interactive terminal"
        }
    }

    private func chooseFolder() {
        if isUITesting {
            selectedFolder = AppEnvironment.uiTestFixtureProjectPath
            return
        }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Choose Project"
        if panel.runModal() == .OK { selectedFolder = panel.url }
    }
}

private struct CreationSection<Content: View>: View {
    let number: String
    let title: String
    let subtitle: String
    @ViewBuilder let content: () -> Content

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            Text(number)
                .font(.caption2.monospacedDigit().weight(.bold))
                .foregroundStyle(FlotillaColors.accent)
                .frame(width: 24, height: 24)
                .background(FlotillaColors.accent.opacity(0.12), in: Circle())

            VStack(alignment: .leading, spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.headline)
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                content()
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

// `EffortLevelPicker` lives in EffortLevelPicker.swift.

/// A dropdown of the current `agent`'s available models — fetched live from
/// the installed CLI (`AgentKit.ModelCatalogCache`), falling back to a small
/// static shortlist if that fails — plus a "Custom…" option that reveals a
/// text field. `model` is the resolved value passed straight to
/// `AppStore.createSession` — empty means "agent's own default".
struct ModelPickerView: View {
    let agent: AgentKind
    let openCodeSubscription: OpenCodeSubscription
    @Binding var model: String

    @State private var selection = ""
    @State private var customText = ""
    @State private var availableModels: [String] = []
    @State private var isLoading = true

    private let customTag = "__custom__"

    var body: some View {
        HStack(spacing: 8) {
            Picker("Model", selection: $selection) {
                Text("Default").tag("")
                ForEach(availableModels, id: \.self) { preset in
                    Text(preset).tag(preset)
                }
                Text("Custom…").tag(customTag)
            }
            .labelsHidden()
            .onChange(of: selection) { _, newValue in
                model = newValue == customTag ? customText : newValue
            }

            if isLoading {
                ProgressView()
                    .controlSize(.small)
                    .help("Fetching available models from the CLI…")
            }

            if selection == customTag {
                TextField("Model name", text: $customText)
                    .textFieldStyle(.roundedBorder)
                    .onChange(of: customText) { _, newValue in
                        model = newValue
                    }
            }
        }
        // `.task(id:)` re-fetches (cancelling any in-flight fetch) whenever
        // `agent` changes. A model chosen for one agent is almost never
        // valid for another, so switching resets back to "Default" rather
        // than silently carrying a stale value.
        .task(id: agent) {
            selection = ""
            customText = ""
            model = ""
            isLoading = true
            availableModels = await ModelCatalogCache.shared.models(for: agent, openCodeSubscription: openCodeSubscription)
            isLoading = false
            syncSelection(presets: availableModels)
        }
    }

    private func syncSelection(presets: [String]) {
        if model.isEmpty {
            selection = ""
        } else if presets.contains(model) {
            selection = model
        } else {
            selection = customTag
            customText = model
        }
    }
}

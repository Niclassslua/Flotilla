import SwiftUI
import AppKit
import SessionKit
import DesignSystem

struct CreateSessionView: View {
    @Bindable var store: AppStore
    @Environment(\.dismiss) private var dismiss

    let defaultAgent: AgentKind
    let createWorktreeByDefault: Bool
    let initialProject: Project?
    let didCreateSession: (UUID) -> Void

    @State private var isGeneralSession = true
    @State private var selectedFolder: URL?
    @State private var goal = ""
    @State private var agent: AgentKind
    @State private var checkoutMode: CheckoutMode = .mainCheckout
    @State private var isCreating = false
    @State private var showsPrompt = false
    @State private var projectQuery = ""

    init(
        store: AppStore,
        defaultAgent: AgentKind = .claudeCode,
        createWorktreeByDefault: Bool = true,
        initialProject: Project? = nil,
        didCreateSession: @escaping (UUID) -> Void = { _ in }
    ) {
        self.store = store
        self.defaultAgent = defaultAgent
        self.createWorktreeByDefault = createWorktreeByDefault
        self.initialProject = initialProject
        self.didCreateSession = didCreateSession
        _isGeneralSession = State(initialValue: initialProject == nil)
        _selectedFolder = State(initialValue: initialProject?.rootPath)
        _agent = State(initialValue: defaultAgent)
        _checkoutMode = State(initialValue: createWorktreeByDefault ? .newWorktree : .mainCheckout)
    }

    private var isUITesting: Bool {
        ProcessInfo.processInfo.environment["UI_TESTING"] == "1"
    }

    private var canCreate: Bool {
        !goal.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && (isGeneralSession || selectedFolder != nil)
            && !isCreating
    }

    var body: some View {
        Group {
            if isUITesting || showsPrompt {
                promptedSessionBody
            } else {
                quickSessionBody
            }
        }
    }

    private var promptedSessionBody: some View {
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
                        Label(error, systemImage: "exclamationmark.triangle.fill")
                            .font(.callout)
                            .foregroundStyle(.red)
                            .padding(12)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(Color.red.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
                            .accessibilityIdentifier("CreateSession.ErrorMessage")
                    }
                }
                .padding(FlotillaSpacing.xLarge)
            }
            Divider()
            footer
        }
        .frame(minWidth: 560, idealWidth: 640, minHeight: 560, idealHeight: 640)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private var quickSessionBody: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                ZStack {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(FlotillaPalette.ocean)
                    Image(systemName: "plus")
                        .font(.system(size: 16, weight: .bold))
                        .foregroundStyle(.white)
                }
                .frame(width: 36, height: 36)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Quick Session")
                        .font(.title3.weight(.semibold))
                    Text("Choose where the agent should start.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }
            .padding(18)

            Divider()

            VStack(spacing: 12) {
                HStack(spacing: 8) {
                    Image(systemName: "magnifyingglass")
                        .foregroundStyle(.secondary)
                    TextField("Search projects", text: $projectQuery)
                        .textFieldStyle(.plain)
                }
                .padding(.horizontal, 11)
                .frame(height: 34)
                .background(FlotillaPalette.elevated, in: RoundedRectangle(cornerRadius: 6))

                ScrollView {
                    LazyVStack(spacing: 5) {
                        quickSourceRow(
                            title: "General Session",
                            subtitle: FileManager.default.homeDirectoryForCurrentUser.path,
                            systemImage: "terminal",
                            selected: isGeneralSession
                        ) {
                            isGeneralSession = true
                            selectedFolder = nil
                            checkoutMode = .mainCheckout
                        }

                        ForEach(matchingProjects) { project in
                            quickSourceRow(
                                title: project.name,
                                subtitle: project.rootPath.path,
                                systemImage: "folder.fill",
                                selected: !isGeneralSession && selectedFolder == project.rootPath
                            ) {
                                isGeneralSession = false
                                selectedFolder = project.rootPath
                                checkoutMode = createWorktreeByDefault ? .newWorktree : .mainCheckout
                            }
                        }
                    }
                }
                .frame(maxHeight: 245)

                if !isGeneralSession {
                    Toggle(isOn: worktreeBinding) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Create in a new worktree")
                            Text("Keep this session isolated from the main checkout.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .toggleStyle(.switch)
                    .padding(.horizontal, 2)
                }

                Button {
                    showsPrompt = true
                } label: {
                    HStack {
                        Image(systemName: "text.bubble")
                        Text("Create session with prompt")
                        Spacer()
                        Image(systemName: "chevron.right")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    }
                    .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .padding(11)
                .background(FlotillaPalette.elevated, in: RoundedRectangle(cornerRadius: 6))
            }
            .padding(16)

            Divider()

            HStack {
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Spacer()
                if isCreating { ProgressView().controlSize(.small) }
                Button("Background") { launchQuick(opensSession: false) }
                    .disabled(isCreating)
                Button("Start Session") { launchQuick(opensSession: true) }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(isCreating)
            }
            .padding(16)
        }
        .frame(width: 560)
        .background(FlotillaPalette.panel)
    }

    private var matchingProjects: [Project] {
        guard !projectQuery.isEmpty else { return store.projects }
        return store.projects.filter {
            $0.name.localizedCaseInsensitiveContains(projectQuery)
                || $0.rootPath.path.localizedCaseInsensitiveContains(projectQuery)
        }
    }

    private var worktreeBinding: Binding<Bool> {
        Binding(
            get: { checkoutMode == .newWorktree },
            set: { checkoutMode = $0 ? .newWorktree : .mainCheckout }
        )
    }

    private func quickSourceRow(
        title: String,
        subtitle: String,
        systemImage: String,
        selected: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: systemImage)
                    .foregroundStyle(selected ? FlotillaPalette.ocean : .secondary)
                    .frame(width: 22)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.callout.weight(.medium))
                        .foregroundStyle(.primary)
                    Text(subtitle)
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Spacer()
                if selected {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(FlotillaPalette.ocean)
                }
            }
            .padding(.horizontal, 10)
            .frame(height: 50)
            .background(selected ? FlotillaPalette.ocean.opacity(0.09) : .clear, in: RoundedRectangle(cornerRadius: 6))
            .overlay {
                RoundedRectangle(cornerRadius: 6)
                    .strokeBorder(selected ? FlotillaPalette.ocean.opacity(0.55) : FlotillaPalette.subtleStroke)
            }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
    }

    private func launchQuick(opensSession: Bool) {
        isCreating = true
        let title = isGeneralSession ? "General session" : (selectedFolder?.lastPathComponent ?? "New session")
        Task {
            await store.createSession(
                title: title,
                goal: "",
                agent: agent,
                projectFolder: isGeneralSession ? nil : selectedFolder,
                checkoutMode: checkoutMode,
                deliverGoal: false
            )
            isCreating = false
            guard store.lastCreationError == nil else { return }
            if opensSession, let id = store.selectedSessionID { didCreateSession(id) }
            dismiss()
        }
    }

    private var header: some View {
        HStack(spacing: 14) {
            ZStack {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(FlotillaPalette.ocean)
                Image(systemName: "point.3.connected.trianglepath.dotted")
                    .font(.system(size: 24, weight: .semibold))
                    .foregroundStyle(.white)
            }
            .frame(width: 48, height: 48)
            .shadow(color: FlotillaPalette.ocean.opacity(0.25), radius: 10, y: 4)

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
                        .foregroundStyle(selectedFolder == nil ? Color.secondary : FlotillaPalette.ocean)
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
                .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .animation(.snappy(duration: 0.22), value: isGeneralSession)
    }

    private var goalSection: some View {
        CreationSection(number: "02", title: "Set the objective", subtitle: "This is sent directly to the selected CLI after its PTY starts.") {
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
                    Text(kind.displayName).tag(kind)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .controlSize(.large)
            .accessibilityIdentifier("CreateSession.AgentPicker")

            HStack(spacing: 8) {
                Image(systemName: agentIcon)
                    .foregroundStyle(FlotillaPalette.ocean)
                Text(agentDescription)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Text("Credentials stay in the CLI")
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var checkoutSection: some View {
        CreationSection(number: "04", title: "Choose isolation", subtitle: "A worktree keeps this agent’s edits separate from your main checkout.") {
            Picker("Checkout", selection: $checkoutMode) {
                Label("Main Checkout", systemImage: "shippingbox")
                    .tag(CheckoutMode.mainCheckout)
                Label("New Worktree", systemImage: "arrow.triangle.branch")
                    .tag(CheckoutMode.newWorktree)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .controlSize(.large)
            .accessibilityIdentifier("CreateSession.CheckoutPicker")

            HStack(spacing: 8) {
                Image(systemName: checkoutMode == .newWorktree ? "checkmark.shield.fill" : "exclamationmark.triangle")
                    .foregroundStyle(checkoutMode == .newWorktree ? FlotillaPalette.ocean : Color.secondary)
                Text(checkoutMode == .newWorktree
                     ? "Creates a dedicated branch and worktree under your configured base directory."
                     : "The agent edits the selected checkout directly; concurrent sessions can conflict.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("CreateSession.CheckoutDescription")
            }
            .animation(.easeInOut(duration: 0.16), value: checkoutMode)
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
            Button("Launch Session") {
                launchPrompted()
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
        String(goal.trimmingCharacters(in: .whitespacesAndNewlines).prefix(60))
    }

    private func launchPrompted() {
        Task {
            isCreating = true
            await store.createSession(
                title: sessionTitle,
                goal: goal,
                agent: agent,
                projectFolder: isGeneralSession ? nil : selectedFolder,
                checkoutMode: checkoutMode
            )
            isCreating = false
            if store.lastCreationError == nil {
                if let id = store.selectedSessionID { didCreateSession(id) }
                dismiss()
            }
        }
    }

    private var agentIcon: String {
        switch agent {
        case .claudeCode: "sparkle"
        case .codexCLI: "chevron.left.forwardslash.chevron.right"
        case .geminiCLI: "diamond"
        }
    }

    private var agentDescription: String {
        switch agent {
        case .claudeCode: "Claude Code in an interactive terminal"
        case .codexCLI: "Codex CLI in an interactive terminal"
        case .geminiCLI: "Gemini CLI in an interactive terminal"
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
    let content: Content

    init(number: String, title: String, subtitle: String, @ViewBuilder content: () -> Content) {
        self.number = number
        self.title = title
        self.subtitle = subtitle
        self.content = content()
    }

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            Text(number)
                .font(.caption2.monospacedDigit().weight(.bold))
                .foregroundStyle(FlotillaPalette.ocean)
                .frame(width: 24, height: 24)
                .background(FlotillaPalette.ocean.opacity(0.12), in: Circle())

            VStack(alignment: .leading, spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.headline)
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                content
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

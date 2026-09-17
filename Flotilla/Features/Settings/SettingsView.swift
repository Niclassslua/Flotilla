import SwiftUI
import AppKit
import AgentKit
import ProcessKit
import SessionKit
import SettingsKit
import DesignSystem

private enum SettingsTab: String, CaseIterable, Identifiable {
    case general
    case sessions
    case terminal
    case git
    case notifications
    case companion
    case agents

    var id: Self { self }

    var title: String {
        switch self {
        case .general: "General"
        case .sessions: "Sessions"
        case .terminal: "Terminal"
        case .git: "Git & Worktrees"
        case .notifications: "Notifications"
        case .companion: "iPhone Companion"
        case .agents: "Coding Agents"
        }
    }

    var icon: String {
        switch self {
        case .general: "gearshape.fill"
        case .sessions: "rectangle.3.group.fill"
        case .terminal: "terminal.fill"
        case .git: "arrow.triangle.branch"
        case .notifications: "bell.fill"
        case .companion: "iphone"
        case .agents: "cpu.fill"
        }
    }

    var color: Color {
        switch self {
        case .general: .gray
        case .sessions: .indigo
        case .terminal: .cyan
        case .git: FlotillaColors.accent
        case .notifications: .red
        case .companion: .green
        case .agents: .purple
        }
    }

    var searchText: String {
        switch self {
        case .general: "worktrees workspace grid density directory appearance light dark theme"
        case .sessions: "session defaults coding agent prompt worktree"
        case .terminal: "terminal font size scroll option meta editor monaco curly braces"
        case .git: "git branch worktree delete lifecycle"
        case .notifications: "notifications waiting input sound privacy never active always delivery"
        case .companion: "iphone phone companion remote pair pairing qr tailscale lan network devices"
        case .agents: "claude codex opencode agy antigravity executable arguments authentication developer tools git github gh tmux path"
        }
    }
}

struct SettingsView: View {
    @Bindable var viewModel: SettingsViewModel
#if FLOTILLA_EPHEMERAL
    @State private var selectedTabID = SettingsTab.general.rawValue
#else
    @AppStorage("settings.selected-section") private var selectedTabID = SettingsTab.general.rawValue
#endif
    @State private var searchText = ""
    @State private var columnVisibility: NavigationSplitViewVisibility = .all

    var body: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            List(selection: selection) {
                if filteredTabs.isEmpty {
                    Text("No matching settings")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .listRowSeparator(.hidden)
                } else {
                    ForEach(filteredTabs) { tab in
                        SettingsSidebarRow(tab: tab)
                            .tag(tab)
                            .accessibilityIdentifier("settings.sidebar.\(tab.rawValue)")
                    }
                }
            }
            .listStyle(.sidebar)
            .scrollEdgeEffectStyleSoftIfAvailable()
            .navigationTitle("Settings")
            .searchable(text: $searchText, placement: .sidebar, prompt: "Search Settings")
            .navigationSplitViewColumnWidth(min: 190, ideal: 220, max: 260)
            .safeAreaInset(edge: .bottom) {
                Text(appVersion)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .padding(.vertical, 8)
            }
        } detail: {
            detail
                .navigationTitle(selectedTab.title)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .navigationSplitViewStyle(.balanced)
        .frame(minWidth: 720, idealWidth: 800, minHeight: 540, idealHeight: 620)
        .tint(FlotillaColors.accent)
        .background { uiTestWindowPlacer }
        #if DEBUG
        .onAppear { applyUITestSelectionIfNeeded() }
        .overlay(alignment: .topLeading) {
            Text("Settings")
                .accessibilityIdentifier("SettingsView")
                .frame(width: 1, height: 1)
                .opacity(0.001)
                .allowsHitTesting(false)
        }
        #endif
    }

    @ViewBuilder
    private var uiTestWindowPlacer: some View {
        #if DEBUG
        if ProcessInfo.processInfo.environment["UI_TESTING"] == "1" {
            UITestWindowPlacer(placement: .topLeading)
        }
        #endif
    }

    #if DEBUG
    private func applyUITestSelectionIfNeeded() {
        guard ProcessInfo.processInfo.environment["UI_TESTING"] == "1",
              let tabID = ProcessInfo.processInfo.environment["UI_TEST_SETTINGS_SECTION"],
              SettingsTab(rawValue: tabID) != nil else { return }
        selectedTabID = tabID
    }
    #endif

    private var selectedTab: SettingsTab {
        SettingsTab(rawValue: selectedTabID) ?? .general
    }

    private var selection: Binding<SettingsTab?> {
        Binding(
            get: { selectedTab },
            set: { selectedTabID = ($0 ?? .general).rawValue }
        )
    }

    private var filteredTabs: [SettingsTab] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return SettingsTab.allCases }
        return SettingsTab.allCases.filter {
            "\($0.title) \($0.searchText)".localizedCaseInsensitiveContains(query)
        }
    }

    private var appVersion: String {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.1"
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "1"
        return "Flotilla \(version) (\(build))"
    }

    @ViewBuilder
    private var detail: some View {
        switch selectedTab {
        case .general:
            GeneralSettingsPane(viewModel: viewModel)
        case .sessions:
            SessionSettingsPane(viewModel: viewModel)
        case .terminal:
            TerminalSettingsPane(viewModel: viewModel)
        case .git:
            GitSettingsPane(viewModel: viewModel)
        case .notifications:
            NotificationSettingsPane(viewModel: viewModel)
        case .companion:
            CompanionSettingsPane()
        case .agents:
            AgentSettingsPane(viewModel: viewModel)
        }
    }
}

private struct SettingsSidebarRow: View {
    let tab: SettingsTab

    var body: some View {
        Label {
            Text(tab.title)
        } icon: {
            Group {
                if tab == .git {
                    GitIcon(size: 13)
                } else {
                    Image(systemName: tab.icon)
                        .font(.system(size: 12, weight: .semibold))
                }
            }
            .foregroundStyle(.white)
            .frame(width: 24, height: 24)
            .background(tab.color, in: .rect(cornerRadius: 6))
        }
        .padding(.vertical, 2)
    }
}

private struct SettingsSectionHeader: View {
    let title: LocalizedStringKey
    let systemImage: String

    init(_ title: LocalizedStringKey, systemImage: String) {
        self.title = title
        self.systemImage = systemImage
    }

    var body: some View {
        Label {
            Text(title)
        } icon: {
            if systemImage == "arrow.triangle.branch" {
                GitBranchIcon(size: 12)
            } else {
                Image(systemName: systemImage)
            }
        }
        .foregroundStyle(.tint)
        .accessibilityElement(children: .combine)
    }
}

private struct GeneralSettingsPane: View {
    @Bindable var viewModel: SettingsViewModel

    var body: some View {
        Form {
            Section {
                Picker("Appearance", selection: $viewModel.settings.appearance) {
                    Text("System").tag(AppearanceMode.system)
                    Text("Light").tag(AppearanceMode.light)
                    Text("Dark").tag(AppearanceMode.dark)
                }
                .pickerStyle(.segmented)
                .accessibilityIdentifier("Settings.AppearancePicker")
            } header: {
                SettingsSectionHeader("Appearance", systemImage: "circle.lefthalf.filled")
            }

            Section {
                LabeledContent("Base directory") {
                    HStack(spacing: 8) {
                        TextField("Base Directory", text: $viewModel.settings.worktreeBaseDirectory)
                            .labelsHidden()
                            .accessibilityIdentifier("Settings.WorktreeBaseDirectory")
                        Button("Choose…") { chooseWorktreeDirectory() }
                    }
                }
                .help("Project instruction files and skills stay in their checkout. Flotilla does not upload them.")
                Text("New isolated checkouts are created here. Existing sessions are never moved. Sessions and their local terminal data stay on this Mac.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } header: {
                SettingsSectionHeader("Worktrees", systemImage: "square.stack.3d.up")
            }

            Section {
                Toggle("Show labels on sidebar icons", isOn: $viewModel.settings.workspace.sidebarRailLabels)
                    .toggleStyle(.switch)
                Text("Labels make Overview, Sessions, and Projects easier to tell apart at a glance, at the cost of a wider rail.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } header: {
                SettingsSectionHeader("Sidebar", systemImage: "sidebar.left")
            }
        }
        .flotillaSettingsFormLayout()
    }

    private func chooseWorktreeDirectory() {
        if ProcessInfo.processInfo.environment["UI_TESTING"] == "1" {
            viewModel.settings.worktreeBaseDirectory = "/tmp/flotilla-custom-worktrees"
            return
        }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url {
            viewModel.settings.worktreeBaseDirectory = url.path
        }
    }
}

private struct SessionSettingsPane: View {
    @Bindable var viewModel: SettingsViewModel

    var body: some View {
        Form {
            Section {
                Picker("Default agent", selection: Binding(
                    get: { AgentKind(rawValue: viewModel.settings.sessionDefaults.defaultAgentRawValue) ?? .claudeCode },
                    set: { viewModel.settings.sessionDefaults.defaultAgentRawValue = $0.rawValue }
                )) {
                    ForEach(AgentKind.allCases) { kind in
                        Text(kind.displayName).tag(kind)
                    }
                }
                .accessibilityIdentifier("Settings.DefaultAgentPicker")

                Toggle("Create a worktree for project sessions", isOn: $viewModel.settings.sessionDefaults.createWorktreeByDefault)
                    .toggleStyle(.switch)
                Picker("Session naming", selection: $viewModel.settings.sessionDefaults.namingSource) {
                    ForEach(SessionNamingSource.allCases) { source in
                        Text(source.displayName).tag(source)
                    }
                }
                .accessibilityIdentifier("Settings.SessionNamingSource")
            } header: {
                SettingsSectionHeader("Defaults", systemImage: "slider.horizontal.3")
            } footer: {
                VStack(alignment: .leading, spacing: 4) {
                    Text("New sessions open with this agent preselected.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text("Session naming also sets a new worktree's branch and folder. The agent-managed option starts in the main checkout until the agent chooses a name.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .flotillaSettingsFormLayout()
    }
}

private struct TerminalSettingsPane: View {
    @Bindable var viewModel: SettingsViewModel

    var body: some View {
        Form {
            Section {
                LabeledContent("Font size") {
                    HStack(spacing: 12) {
                        Slider(value: $viewModel.settings.terminal.fontSize, in: 10...22, step: 1)
                            .frame(width: 180)
                        Text("\(Int(viewModel.settings.terminal.fontSize)) pt")
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                            .frame(width: 42, alignment: .trailing)
                    }
                }
                Toggle("Use Option as Meta", isOn: $viewModel.settings.terminal.optionActsAsMeta)
                    .toggleStyle(.switch)
                LabeledContent("Scroll speed") {
                    Slider(value: $viewModel.settings.terminal.scrollSpeed, in: 0.5...2, step: 0.1)
                        .frame(width: 180)
                }
                Toggle("GPU Rendering (Metal)", isOn: $viewModel.settings.terminal.gpuRendering)
                    .toggleStyle(.switch)
            } header: {
                SettingsSectionHeader("Terminal", systemImage: "terminal")
            }

            Section {
                LabeledContent("Font size") {
                    HStack(spacing: 12) {
                        Slider(value: $viewModel.settings.terminal.editorFontSize, in: 10...22, step: 1)
                            .frame(width: 180)
                            .accessibilityIdentifier("Settings.EditorFontSize")
                        Text("\(Int(viewModel.settings.terminal.editorFontSize)) pt")
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                            .frame(width: 42, alignment: .trailing)
                    }
                }
                Text("Used by the code editor in Projects → Files. The Monaco-based editor applies this size immediately.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } header: {
                SettingsSectionHeader("Editor", systemImage: "curlybraces")
            }
        }
        .flotillaSettingsFormLayout()
    }
}

private struct GitSettingsPane: View {
    @Bindable var viewModel: SettingsViewModel
    @State private var isConfirmingAttributionDeletion = false

    var body: some View {
        Form {
            Section {
                Toggle("Delete branch when deleting its worktree", isOn: $viewModel.settings.git.deleteBranchWithWorktree)
                    .toggleStyle(.switch)
                Text("Deleting a session always asks before removing an isolated checkout. The main checkout is never deleted.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } header: {
                SettingsSectionHeader("Worktree Lifecycle", systemImage: "arrow.triangle.branch")
            }

            Section {
                Toggle("Fetch before creating a worktree", isOn: $viewModel.settings.git.fetchBeforeCreatingWorktree)
                    .toggleStyle(.switch)
                Text("Refreshes remote-tracking branches first, so a new worktree isn't cut from stale refs. Off by default to keep session launch fast; a failed fetch never blocks worktree creation.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } header: {
                SettingsSectionHeader("Worktree Creation", systemImage: "arrow.down.circle")
            }

            Section {
                Toggle("Highlight commits you haven't seen", isOn: $viewModel.settings.git.highlightUnseenCommits)
                    .toggleStyle(.switch)
                    .accessibilityIdentifier("Settings.HighlightUnseenCommits")
                Text("Marks commits in a project's History that landed since you last opened it — useful when agents commit while you're away. The marker advances when you leave the History view.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Picker("Commit attribution", selection: $viewModel.settings.git.defaultCommitAttribution) {
                    ForEach(CommitAttributionMode.allCases) { mode in
                        Text(mode.displayName).tag(mode)
                    }
                }
                .accessibilityIdentifier("Settings.CommitAttribution")
                Text(Self.commitAttributionExplanation(viewModel.settings.git.defaultCommitAttribution))
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Button("Delete Records on This Mac…") {
                    isConfirmingAttributionDeletion = true
                }
                .disabled(viewModel.deleteLocalAttributionRecords == nil)
                .confirmationDialog(
                    "Delete commit attribution recorded on this Mac?",
                    isPresented: $isConfirmingAttributionDeletion,
                    titleVisibility: .visible
                ) {
                    Button("Delete Records", role: .destructive) {
                        viewModel.deleteLocalAttributionRecords?()
                    }
                    Button("Cancel", role: .cancel) {}
                } message: {
                    Text("History will no longer show which session, agent, model and prompt made the commits recorded on this Mac. Markers already committed to repositories are not affected.")
                }
            } header: {
                SettingsSectionHeader("Commit History", systemImage: "clock.arrow.circlepath")
            }
        }
        .flotillaSettingsFormLayout()
    }

    private static func commitAttributionExplanation(_ mode: CommitAttributionMode) -> String {
        let override = " Each project can choose differently from its project menu."
        switch mode {
        case .off:
            return "Commits made in agent sessions aren't recorded. History still shows attribution recorded earlier." + override
        case .local:
            return "Flotilla records the session, agent, model and prompt behind each commit in its database on this Mac. Nothing is written into your repositories. Flotilla follows rewrites reported by Git and reconnects unique matching patches when possible." + override
        case .shared:
            return "Agent commits using the attribution hook add an empty marker file under .flotilla/sessions, plus the session's prompt once, so attribution travels with the repository to every clone. The prompt stays in the repository's history." + override
        }
    }
}

private struct NotificationSettingsPane: View {
    @Bindable var viewModel: SettingsViewModel

    var body: some View {
        Form {
            Section {
                Picker("Show notifications", selection: $viewModel.settings.notifications.delivery) {
                    ForEach(NotificationDelivery.allCases) { delivery in
                        Text(delivery.displayName).tag(delivery)
                    }
                }
                .accessibilityIdentifier(AXID.settingsNotificationDeliveryPicker.rawValue)

                Toggle("Agent is waiting for input", isOn: $viewModel.settings.notifications.waitingForInputEnabled)
                    .toggleStyle(.switch)
                    .disabled(viewModel.settings.notifications.delivery == .never)
                Toggle("Session finished", isOn: $viewModel.settings.notifications.finishedEnabled)
                    .toggleStyle(.switch)
                    .disabled(viewModel.settings.notifications.delivery == .never)
                Text("The system notification uses the Mac’s current notification sound and Focus settings.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } header: {
                SettingsSectionHeader("Session Events", systemImage: "bell")
            } footer: {
                Text("Notifications observe terminal output and process state. They never approve agent prompts.")
            }
        }
        .flotillaSettingsFormLayout()
    }
}

private struct AgentSettingsPane: View {
    @Bindable var viewModel: SettingsViewModel
    @State private var toolScanGeneration = UUID()

    var body: some View {
        Form {
            ForEach(AgentKind.allCases) { agent in
                Section {
                    LabeledContent("Executable") {
                        HStack(spacing: 8) {
                            TextField("Find automatically", text: pathBinding(for: agent))
                                .labelsHidden()
                                .accessibilityIdentifier(pathIdentifier(for: agent))
                            Button("Choose…") { chooseExecutable(for: agent) }
                        }
                    }
                    // "Find automatically" left the resolved binary invisible:
                    // there was no way to see what Flotilla would actually
                    // launch, or whether the agent was detected at all.
                    AgentExecutableStatusRow(
                        agent: agent,
                        configuredPath: pathBinding(for: agent).wrappedValue,
                        locator: PATHExecutableLocator()
                    )
                    .help("Flotilla starts this CLI locally. Authentication remains in the CLI; Flotilla does not store its credentials.")
                    LabeledContent("Arguments") {
                        TextEditor(text: argumentsBinding(for: agent))
                            .font(.system(.callout, design: .monospaced))
                            .frame(minHeight: 54, maxHeight: 84)
                            .overlay {
                                RoundedRectangle(cornerRadius: 5)
                                    .strokeBorder(Color(nsColor: .separatorColor))
                            }
                    }
                    Text("Enter one argument per line. The session goal is delivered through the PTY after launch.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } header: {
                    SettingsSectionHeader(LocalizedStringKey(agent.displayName), systemImage: "cpu")
                }
                if agent == .openCode {
                    Section {
                        Picker("OpenCode subscription", selection: $viewModel.settings.openCodeSubscription) {
                            Text("None").tag(OpenCodeSubscription.none)
                            Text("Zen").tag(OpenCodeSubscription.zen)
                            Text("Go").tag(OpenCodeSubscription.go)
                        }
                        .pickerStyle(.segmented)
                    } header: {
                        SettingsSectionHeader("OpenCode Plan", systemImage: "network")
                    }
                }
            }

            Section {
                ForEach(["git", "gh", "tmux"], id: \.self) { tool in
                    ToolStatusRow(name: tool, locator: PATHExecutableLocator())
                }
                .id(toolScanGeneration)
                Button("Rescan Tools") { toolScanGeneration = UUID() }
            } header: {
                SettingsSectionHeader("Supporting Tools", systemImage: "wrench.and.screwdriver")
            } footer: {
                Text("Flotilla checks your PATH and common local install locations. An explicit agent executable path takes priority.")
            }
        }
        .flotillaSettingsFormLayout()
    }

    private func pathBinding(for agent: AgentKind) -> Binding<String> {
        let key = AgentCatalog.descriptor(for: agent).settingsKey
        return Binding {
            viewModel.settings.agentOverrides.paths[key] ?? ""
        } set: { value in
            if value.isEmpty {
                viewModel.settings.agentOverrides.paths.removeValue(forKey: key)
            } else {
                viewModel.settings.agentOverrides.paths[key] = value
            }
        }
    }

    private func argumentsBinding(for agent: AgentKind) -> Binding<String> {
        let key = AgentCatalog.descriptor(for: agent).settingsKey
        return Binding {
            (viewModel.settings.agentOverrides.arguments[key] ?? []).joined(separator: "\n")
        } set: { value in
            let parsed = value.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
            if parsed.isEmpty {
                viewModel.settings.agentOverrides.arguments.removeValue(forKey: key)
            } else {
                viewModel.settings.agentOverrides.arguments[key] = parsed
            }
        }
    }

    private func pathIdentifier(for agent: AgentKind) -> String {
        "\(AgentCatalog.descriptor(for: agent).accessibilityIDPrefix)Path"
    }

    private func chooseExecutable(for agent: AgentKind) {
        if ProcessInfo.processInfo.environment["UI_TESTING"] == "1" {
            pathBinding(for: agent).wrappedValue = "/usr/bin/\(agent.rawValue)"
            return
        }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url {
            pathBinding(for: agent).wrappedValue = url.path
        }
    }
}

/// What Flotilla will actually launch for one agent, and where that came from.
/// Mirrors `ToolStatusRow`, but has to resolve the same way the launcher does:
/// an explicit, executable path in Settings wins; otherwise discovery on the
/// augmented PATH. Never colour alone — the state is always written out.
private struct AgentExecutableStatusRow: View {
    let agent: AgentKind
    let configuredPath: String
    let locator: any ExecutableLocating

    private enum Resolution {
        case explicit(URL)
        case discovered(URL)
        /// A path is set in Settings but is not an executable file.
        case explicitMissing(String)
        case notFound(binary: String)
    }

    private var resolution: Resolution {
        let binary = AgentCatalog.descriptor(for: agent).binaryName
        let trimmed = configuredPath.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty {
            return FileManager.default.isExecutableFile(atPath: trimmed)
                ? .explicit(URL(fileURLWithPath: trimmed))
                : .explicitMissing(trimmed)
        }
        if let found = locator.locate(binary) { return .discovered(found) }
        return .notFound(binary: binary)
    }

    private var isResolved: Bool {
        switch resolution {
        case .explicit, .discovered: true
        case .explicitMissing, .notFound: false
        }
    }

    private var detail: String {
        switch resolution {
        case .explicit(let url): url.path
        case .discovered(let url): url.path
        case .explicitMissing(let path): "Not executable: \(path)"
        case .notFound(let binary): "\(binary) not found on PATH"
        }
    }

    private var origin: String {
        switch resolution {
        case .explicit: "Set in Settings"
        case .discovered: "Found automatically"
        case .explicitMissing: "Check the path above"
        case .notFound: "Install it, or choose a path above"
        }
    }

    var body: some View {
        LabeledContent("Resolved") {
            VStack(alignment: .trailing, spacing: 2) {
                HStack(spacing: 7) {
                    Circle()
                        .fill(isResolved ? FlotillaColors.accent : Color.orange)
                        .frame(width: 7, height: 7)
                        .accessibilityHidden(true)
                    Text(detail)
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(isResolved ? .primary : .secondary)
                        .textSelection(.enabled)
                        .lineLimit(2)
                        .truncationMode(.middle)
                }
                Text(origin)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("\(AgentCatalog.descriptor(for: agent).accessibilityIDPrefix)Resolved")
    }
}

private struct ToolStatusRow: View {
    let name: String
    let locator: any ExecutableLocating

    var body: some View {
        let location = locator.locate(name)
        LabeledContent(name) {
            HStack(spacing: 7) {
                Circle()
                    .fill(location == nil ? Color.orange : FlotillaColors.accent)
                    .frame(width: 7, height: 7)
                Text(location?.path ?? "Not found")
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(location == nil ? .secondary : .primary)
                    .textSelection(.enabled)
            }
        }
    }
}

private extension View {
    func flotillaSettingsFormLayout(maxWidth: CGFloat = 720) -> some View {
        formStyle(.grouped)
            .scrollContentBackground(.hidden)
            .contentMargins(.top, 8, for: .scrollContent)
            .padding(16)
            .frame(maxWidth: maxWidth, maxHeight: .infinity, alignment: .topLeading)
    }

    @ViewBuilder
    func scrollEdgeEffectStyleSoftIfAvailable() -> some View {
        if #available(macOS 26.0, *) {
            scrollEdgeEffectStyle(.soft, for: .all)
        } else {
            self
        }
    }
}

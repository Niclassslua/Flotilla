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
    case agents
    // case appearance  // Removed - dark mode only for now
    case projects
    case environment
    case advanced

    var id: Self { self }

    var title: String {
        switch self {
        case .general: "General"
        case .sessions: "Sessions"
        case .terminal: "Terminal & Editor"
        case .git: "Git & Worktrees"
        case .notifications: "Notifications"
        case .agents: "Coding Agents"
        // case .appearance: "Appearance"
        case .projects: "Projects"
        case .environment: "Developer Tools"
        case .advanced: "Advanced"
        }
    }

    var icon: String {
        switch self {
        case .general: "gearshape.fill"
        case .sessions: "rectangle.3.group.fill"
        case .terminal: "terminal.fill"
        case .git: "arrow.triangle.branch"
        case .notifications: "bell.fill"
        case .agents: "cpu.fill"
        // case .appearance: "paintbrush.fill"
        case .projects: "folder.fill"
        case .environment: "wrench.and.screwdriver.fill"
        case .advanced: "slider.horizontal.3"
        }
    }

    var color: Color {
        switch self {
        case .general: .gray
        case .sessions: .indigo
        case .terminal: .cyan
        case .git: .green
        case .notifications: .red
        case .agents: .purple
        // case .appearance: .pink
        case .projects: .blue
        case .environment: .orange
        case .advanced: .teal
        }
    }

    var searchText: String {
        switch self {
        case .general: "worktrees workspace grid density directory"
        case .sessions: "session defaults coding agent prompt worktree"
        case .terminal: "terminal editor font size scroll option meta"
        case .git: "git branch worktree delete lifecycle"
        case .notifications: "notifications waiting input sound privacy"
        case .agents: "claude codex opencode executable arguments authentication"
        // case .appearance: "appearance theme system light dark"
        case .projects: "projects paths rules skills local"
        case .environment: "developer tools git github gh tmux path"
        case .advanced: "advanced local storage sqlite pty about"
        }
    }
}

struct SettingsView: View {
    @Bindable var viewModel: SettingsViewModel
    @AppStorage("settings.selected-section") private var selectedTabID = SettingsTab.general.rawValue
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
        #if DEBUG
        .overlay(alignment: .topLeading) {
            Text("Settings")
                .accessibilityIdentifier("SettingsView")
                .frame(width: 1, height: 1)
                .opacity(0.001)
                .allowsHitTesting(false)
        }
        #endif
    }

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
        case .agents:
            AgentSettingsPane(viewModel: viewModel)
        // case .appearance:
            // AppearanceSettingsPane(viewModel: viewModel)
        case .projects:
            ProjectSettingsPane(viewModel: viewModel)
        case .environment:
            EnvironmentSettingsPane()
        case .advanced:
            AdvancedSettingsPane()
        }
    }
}

private struct SettingsSidebarRow: View {
    let tab: SettingsTab

    var body: some View {
        Label {
            Text(tab.title)
        } icon: {
            Image(systemName: tab.icon)
                .font(.system(size: 12, weight: .semibold))
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
            Image(systemName: systemImage)
                .foregroundStyle(.tint)
        }
        .accessibilityElement(children: .combine)
    }
}

private struct GeneralSettingsPane: View {
    @Bindable var viewModel: SettingsViewModel

    var body: some View {
        Form {
            Section {
                LabeledContent("Base directory") {
                    HStack(spacing: 8) {
                        TextField("Base Directory", text: $viewModel.settings.worktreeBaseDirectory)
                            .labelsHidden()
                            .accessibilityIdentifier("Settings.WorktreeBaseDirectory")
                        Button("Choose…") { chooseWorktreeDirectory() }
                    }
                }
                Text("New isolated checkouts are created here. Existing sessions are never moved.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } header: {
                SettingsSectionHeader("Worktrees", systemImage: "square.stack.3d.up")
            }

            Section {
                LabeledContent("Tile density") {
                    HStack(spacing: 12) {
                        Slider(
                            value: $viewModel.settings.workspace.gridMinimumTileWidth,
                            in: 280...560,
                            step: 20
                        )
                        .frame(width: 190)
                        Text(densityLabel)
                            .foregroundStyle(.secondary)
                            .frame(width: 70, alignment: .trailing)
                    }
                }
                Text("Smaller tiles show more live sessions at once; larger tiles favor terminal readability.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } header: {
                SettingsSectionHeader("Grid Workspace", systemImage: "rectangle.3.group")
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

    private var densityLabel: String {
        switch viewModel.settings.workspace.gridMinimumTileWidth {
        case ..<340: "Dense"
        case 340..<460: "Balanced"
        default: "Roomy"
        }
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
                Toggle("Create a worktree for project sessions", isOn: $viewModel.settings.sessionDefaults.createWorktreeByDefault)
                    .toggleStyle(.switch)
            } header: {
                SettingsSectionHeader("Defaults", systemImage: "slider.horizontal.3")
            }

            Section {
                Text("Flotilla sends the goal unchanged through the interactive PTY after the selected CLI starts. It does not prepend instructions, inject permissions, or handle authentication.")
                    .foregroundStyle(.secondary)
            } header: {
                SettingsSectionHeader("Prompt Delivery", systemImage: "text.bubble")
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
                Text("Files and instruction documents open in Flotilla’s native text editor. ⌘S saves the active document to disk.")
                    .foregroundStyle(.secondary)
            } header: {
                SettingsSectionHeader("Editor", systemImage: "doc.text")
            }
        }
        .flotillaSettingsFormLayout()
    }
}

private struct GitSettingsPane: View {
    @Bindable var viewModel: SettingsViewModel

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
        }
        .flotillaSettingsFormLayout()
    }
}

private struct NotificationSettingsPane: View {
    @Bindable var viewModel: SettingsViewModel

    var body: some View {
        Form {
            Section {
                Toggle("Agent is waiting for input", isOn: $viewModel.settings.notifications.waitingForInputEnabled)
                    .toggleStyle(.switch)
                Text("The system notification uses the Mac’s current notification sound and Focus settings.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } header: {
                SettingsSectionHeader("Session Events", systemImage: "bell")
            }

            Section {
                Text("Notifications are produced by a read-only observer of PTY output and process state. They never approve prompts or grant the agent file-system or network access.")
                    .foregroundStyle(.secondary)
            } header: {
                SettingsSectionHeader("Privacy & Permissions", systemImage: "hand.raised")
            }
        }
        .flotillaSettingsFormLayout()
    }
}

private struct AgentSettingsPane: View {
    @Bindable var viewModel: SettingsViewModel

    var body: some View {
        Form {
            Section {
                Text("Flotilla launches each CLI exactly as a terminal would. Authentication remains entirely inside the agent—credentials are never requested or stored here.")
                    .foregroundStyle(.secondary)
            } header: {
                SettingsSectionHeader("Agent Security", systemImage: "lock.shield")
            }

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
        }
        .flotillaSettingsFormLayout()
    }

    private func pathBinding(for agent: AgentKind) -> Binding<String> {
        Binding {
            switch agent {
            case .claudeCode: viewModel.settings.agentPaths.claudeCodePath
            case .codexCLI: viewModel.settings.agentPaths.codexCLIPath
            case .openCode: viewModel.settings.agentPaths.openCodePath
            case .antigravity: viewModel.settings.agentPaths.antigravityPath
            }
        } set: { value in
            switch agent {
            case .claudeCode: viewModel.settings.agentPaths.claudeCodePath = value
            case .codexCLI: viewModel.settings.agentPaths.codexCLIPath = value
            case .openCode: viewModel.settings.agentPaths.openCodePath = value
            case .antigravity: viewModel.settings.agentPaths.antigravityPath = value
            }
        }
    }

    private func argumentsBinding(for agent: AgentKind) -> Binding<String> {
        Binding {
            arguments(for: agent).joined(separator: "\n")
        } set: { value in
            let parsed = value.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
            switch agent {
            case .claudeCode: viewModel.settings.agentArguments.claudeCodeArguments = parsed
            case .codexCLI: viewModel.settings.agentArguments.codexCLIArguments = parsed
            case .openCode: viewModel.settings.agentArguments.openCodeArguments = parsed
            case .antigravity: viewModel.settings.agentArguments.antigravityArguments = parsed
            }
        }
    }

    private func arguments(for agent: AgentKind) -> [String] {
        switch agent {
        case .claudeCode: viewModel.settings.agentArguments.claudeCodeArguments
        case .codexCLI: viewModel.settings.agentArguments.codexCLIArguments
        case .openCode: viewModel.settings.agentArguments.openCodeArguments
        case .antigravity: viewModel.settings.agentArguments.antigravityArguments
        }
    }

    private func pathIdentifier(for agent: AgentKind) -> String {
        switch agent {
        case .claudeCode: "Settings.ClaudeCodePath"
        case .codexCLI: "Settings.CodexCLIPath"
        case .openCode: "Settings.OpenCodePath"
        case .antigravity: "Settings.AntigravityPath"
        }
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

private struct AppearanceSettingsPane: View {
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
                Text("The terminal uses Xirp’s dark palette so agent output stays consistent across sessions.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } header: {
                SettingsSectionHeader("Interface", systemImage: "circle.lefthalf.filled")
            }
        }
        .flotillaSettingsFormLayout()
    }
}

private struct ProjectSettingsPane: View {
    @Bindable var viewModel: SettingsViewModel

    var body: some View {
        Form {
            Section {
                LabeledContent("Worktree base directory") {
                    Text(viewModel.settings.worktreeBaseDirectory)
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Text("Project instruction files and skills stay in their checkout. Flotilla does not upload or catalog them.")
                    .foregroundStyle(.secondary)
            } header: {
                SettingsSectionHeader("Project Defaults", systemImage: "folder")
            }
        }
        .flotillaSettingsFormLayout()
    }
}

private struct EnvironmentSettingsPane: View {
    @State private var generation = UUID()

    var body: some View {
        Form {
            Section {
                ForEach(["git", "gh", "tmux"], id: \.self) { tool in
                    ToolStatusRow(name: tool, locator: PATHExecutableLocator())
                }
                .id(generation)
                Button("Rescan") { generation = UUID() }
            } header: {
                SettingsSectionHeader("Developer Tools", systemImage: "wrench.and.screwdriver")
            }

            Section {
                Text("Flotilla checks the inherited PATH, ~/.local/bin, ~/.cargo/bin, ~/bin, Homebrew on Apple Silicon and Intel, and macOS system locations. An explicit agent path always wins.")
                    .foregroundStyle(.secondary)
            } header: {
                SettingsSectionHeader("How Discovery Works", systemImage: "scope")
            }
        }
        .flotillaSettingsFormLayout()
    }
}

private struct AdvancedSettingsPane: View {
    var body: some View {
        Form {
            Section {
                LabeledContent("Session store", value: "SQLite on this Mac")
                LabeledContent("Agent transport", value: "Local PTY")
                LabeledContent("Git integration", value: "Local git CLI")
                Text("There is no account, organization catalog, fleet router, telemetry pipeline, or hosted backend in this build.")
                    .foregroundStyle(.secondary)
            } header: {
                SettingsSectionHeader("Local-Only Architecture", systemImage: "externaldrive")
            }

            Section {
                HStack(spacing: 14) {
                    Image(nsImage: NSApp.applicationIconImage)
                        .resizable()
                        .frame(width: 56, height: 56)
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Flotilla")
                            .font(.title2.weight(.semibold))
                        Text("A local command center for coding agents")
                            .foregroundStyle(.secondary)
                    }
                }
            } header: {
                SettingsSectionHeader("About", systemImage: "info.circle")
            }
        }
        .flotillaSettingsFormLayout()
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

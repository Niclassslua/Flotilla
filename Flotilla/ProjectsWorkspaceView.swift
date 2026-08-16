import SwiftUI
import AppKit
import SessionKit
import GitKit
import DesignSystem
import SettingsKit

private enum ProjectWorkspaceTab: String, CaseIterable, Identifiable {
    case overview
    case git
    case files
    case skills
    case rules

    var id: Self { self }

    var title: String { rawValue.capitalized }

    var systemImage: String {
        switch self {
        case .overview: "rectangle.grid.1x2"
        case .git: "arrow.triangle.branch"
        case .files: "folder"
        case .skills: "hammer"
        case .rules: "doc.badge.gearshape"
        }
    }
}

struct ProjectsWorkspaceView: View {
    @Bindable var store: AppStore
    @Binding var selectedProjectID: UUID?
    let openSession: (UUID) -> Void
    let openCodeSubscription: OpenCodeSubscription

    @State private var searchText = ""
    @State private var selectedTab: ProjectWorkspaceTab = .overview
    @State private var projectSheet: ProjectSheet?

    private enum ProjectSheet: String, Identifiable {
        case add
        case importWorkspace

        var id: Self { self }
    }

    private var filteredProjects: [Project] {
        guard !searchText.isEmpty else { return store.projects }
        return store.projects.filter {
            $0.name.localizedCaseInsensitiveContains(searchText)
                || $0.rootPath.path.localizedCaseInsensitiveContains(searchText)
        }
    }

    private var selectedProject: Project? {
        store.projects.first { $0.id == selectedProjectID }
    }

    var body: some View {
        Group {
            if let selectedProject {
                NavigationSplitView {
                    List(filteredProjects, selection: $selectedProjectID) { project in
                        HStack(spacing: 9) {
                            ProjectMark(title: project.name, tint: ProjectMark.tint(for: project))
                            VStack(alignment: .leading, spacing: 3) {
                                Text(project.name)
                                    .font(.callout.weight(.medium))
                                Text("\(store.sessions(for: project).count) sessions")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .padding(.vertical, 3)
                        .tag(project.id)
                        .accessibilityIdentifier("ProjectRow-\(project.name)")
                    }
                    .listStyle(.sidebar)
                    .scrollContentBackground(.hidden)
                    .background(FlotillaPalette.sidebar)
                    .searchable(text: $searchText, placement: .sidebar, prompt: "Projects")
                    .safeAreaInset(edge: .top, spacing: 0) { projectSidebarHeader }
                    .navigationSplitViewColumnWidth(min: 210, ideal: 245, max: 320)
                } detail: {
                    ProjectWorkspaceDetail(
                        project: selectedProject,
                        sessions: store.sessions(for: selectedProject),
                        selectedTab: $selectedTab,
                        store: store,
                        openSession: openSession
                    )
                    .id(selectedProject.id)
                }
            } else {
                ProjectCollectionView(
                    projects: filteredProjects,
                    sessionCount: { store.sessions(for: $0).count },
                    select: { selectedProjectID = $0 },
                    add: { projectSheet = .add },
                    importWorkspace: { projectSheet = .importWorkspace }
                )
            }
        }
        .navigationSplitViewStyle(.balanced)
        .background(FlotillaPalette.canvas)
        .sheet(item: $projectSheet) { sheet in
            ProjectPathSheet(importsWorkspace: sheet == .importWorkspace) { paths in
                for path in paths { store.addProject(at: path) }
                projectSheet = nil
            }
        }
    }

    private var projectSidebarHeader: some View {
        HStack {
            VStack(alignment: .leading, spacing: 1) {
                Text("PROJECTS")
                    .font(.caption2.weight(.bold))
                    .tracking(0.9)
                    .foregroundStyle(FlotillaPalette.ocean)
                Text("\(store.projects.count) local workspaces")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button {
                selectedProjectID = nil
            } label: {
                Image(systemName: "square.grid.2x2")
            }
            .buttonStyle(.plain)
            .help("All projects")
            Button {
                projectSheet = .add
            } label: {
                Image(systemName: "plus")
            }
            .buttonStyle(.plain)
            .help("Add project")
            .accessibilityIdentifier("Projects.ImportButton")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 11)
        .background(FlotillaPalette.sidebar)
        .overlay(alignment: .bottom) { Divider() }
    }

    private func importProject() {
        if ProcessInfo.processInfo.environment["UI_TESTING"] == "1" {
            store.addProject(at: AppEnvironment.uiTestFixtureProjectPath)
            selectedProjectID = store.projects.first { $0.rootPath == AppEnvironment.uiTestFixtureProjectPath }?.id
            return
        }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Import Project"
        if panel.runModal() == .OK, let url = panel.url {
            store.addProject(at: url)
            selectedProjectID = store.projects.first { $0.rootPath == url }?.id
        }
    }
}

private struct ProjectCollectionView: View {
    let projects: [Project]
    let sessionCount: (Project) -> Int
    let select: (UUID) -> Void
    let add: () -> Void
    let importWorkspace: () -> Void

    @State private var sortOrder = ProjectSort.recent

    private enum ProjectSort: String, CaseIterable, Identifiable {
        case recent = "Last used"
        case name = "Name"
        case active = "Active"

        var id: Self { self }
    }

    private var sortedProjects: [Project] {
        switch sortOrder {
        case .recent: projects
        case .name: projects.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        case .active: projects.sorted { sessionCount($0) > sessionCount($1) }
        }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Your Projects")
                            .font(.system(size: 22, weight: .semibold))
                        Text("Jump back into a codebase or start an agent in a fresh context.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button(action: importWorkspace) {
                        Label("Import", systemImage: "square.and.arrow.down")
                    }
                    .buttonStyle(.bordered)
                    Button(action: add) {
                        Label("Add Project", systemImage: "plus")
                    }
                    .buttonStyle(.borderedProminent)
                }

                if projects.isEmpty {
                    ContentUnavailableView(
                        "No Projects",
                        systemImage: "folder.badge.plus",
                        description: Text("Import a Git checkout or create a project-scoped session.")
                    )
                    .frame(maxWidth: .infinity, minHeight: 320)
                } else {
                    HStack(spacing: 5) {
                        Text("SORT")
                            .font(.caption2.weight(.bold))
                            .tracking(0.8)
                            .foregroundStyle(.tertiary)
                        ForEach(ProjectSort.allCases) { option in
                            Button(option.rawValue) { sortOrder = option }
                                .buttonStyle(.plain)
                                .font(.caption.weight(sortOrder == option ? .semibold : .regular))
                                .padding(.horizontal, 9)
                                .frame(height: 26)
                                .background(
                                    sortOrder == option ? FlotillaPalette.elevated : .clear,
                                    in: RoundedRectangle(cornerRadius: 5)
                                )
                                .foregroundStyle(sortOrder == option ? .primary : .secondary)
                        }
                    }

                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 300), spacing: 12)], spacing: 12) {
                        ForEach(sortedProjects) { project in
                            Button {
                                select(project.id)
                            } label: {
                                ProjectCompactCard(project: project, sessionCount: sessionCount(project))
                            }
                            .buttonStyle(.plain)
                            .accessibilityIdentifier("ProjectRow-\(project.name)")
                        }
                    }
                }
            }
            .padding(24)
        }
        .background(FlotillaPalette.canvas)
    }
}

private struct ProjectWorkspaceDetail: View {
    let project: Project
    let sessions: [Session]
    @Binding var selectedTab: ProjectWorkspaceTab
    @Bindable var store: AppStore
    let openSession: (UUID) -> Void

    private var projectSession: Session {
        sessions.first ?? Session(
            title: project.name,
            goal: "Project workspace",
            agent: .claudeCode,
            projectID: project.id,
            workingDirectory: project.rootPath
        )
    }

    var body: some View {
        VStack(spacing: 0) {
            projectHeader
            Divider()
            Group {
                switch selectedTab {
                case .overview:
                    ProjectOverviewView(
                        project: project,
                        sessions: sessions,
                        store: store,
                        openSession: openSession
                    )
                case .git:
                    DiffPanelView(session: projectSession, gitService: store.gitService)
                case .files:
                    FileBrowserView(rootURL: project.rootPath)
                case .skills:
                    RulesPanelView(rootURL: project.rootPath, filter: .skills)
                case .rules:
                    RulesPanelView(rootURL: project.rootPath, filter: .rules)
                }
            }
            .id(selectedTab)
        }
    }

    private var projectHeader: some View {
        VStack(alignment: .leading, spacing: 13) {
            HStack(alignment: .center, spacing: 12) {
                Image(systemName: "folder.fill")
                    .font(.title2)
                    .foregroundStyle(FlotillaPalette.ocean)
                VStack(alignment: .leading, spacing: 2) {
                    Text(project.name)
                        .font(.title2.weight(.semibold))
                    Text(project.rootPath.path)
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Spacer()
                Button {
                    NSWorkspace.shared.activateFileViewerSelecting([project.rootPath])
                } label: {
                    Label("Reveal", systemImage: "finder")
                }
            }

            Picker("Project workspace", selection: $selectedTab) {
                ForEach(ProjectWorkspaceTab.allCases) { tab in
                    Label(tab.title, systemImage: tab.systemImage).tag(tab)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(maxWidth: 590)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 14)
        .background(.thinMaterial)
    }
}

private struct ProjectOverviewView: View {
    let project: Project
    let sessions: [Session]
    @Bindable var store: AppStore
    let openSession: (UUID) -> Void
    let openCodeSubscription: OpenCodeSubscription

    @State private var goal = ""
    @State private var agent: AgentKind = .claudeCode
    @State private var model = ""
    @State private var effort: AgentEffort = .medium
    @State private var useWorktree = true
    @State private var isLaunching = false

    init(
        project: Project,
        sessions: [Session],
        store: AppStore,
        openSession: @escaping (UUID) -> Void,
        openCodeSubscription: OpenCodeSubscription = .none
    ) {
        self.project = project
        self.sessions = sessions
        self.store = store
        self.openSession = openSession
        self.openCodeSubscription = openCodeSubscription
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                quickLaunch
                sessionsSection
                worktreesSection
            }
            .padding(22)
            .frame(maxWidth: 980)
            .frame(maxWidth: .infinity)
        }
    }

    private var quickLaunch: some View {
        VStack(alignment: .leading, spacing: 13) {
            Text("Start something new")
                .font(.title2.weight(.semibold))
            TextEditor(text: $goal)
                .font(.body)
                .scrollContentBackground(.hidden)
                .padding(10)
                .frame(minHeight: 88)
                .background(Color(nsColor: .textBackgroundColor))
                .compositingGroup()
                .clipShape(RoundedRectangle(cornerRadius: 10))
                .overlay { RoundedRectangle(cornerRadius: 10).strokeBorder(.separator) }
            HStack {
                Picker("Agent", selection: $agent) {
                    ForEach(AgentKind.allCases) { Text($0.displayName).tag($0) }
                }
                .frame(width: 150)
                ModelPickerView(agent: agent, openCodeSubscription: openCodeSubscription, model: $model)
                EffortGaugePicker(agent: agent, effort: $effort)
                Toggle("New worktree", isOn: $useWorktree)
                    .toggleStyle(.switch)
                Spacer()
                if isLaunching { ProgressView().controlSize(.small) }
                Button("Start Session", action: launch)
                    .buttonStyle(.borderedProminent)
                    .disabled(goal.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isLaunching)
            }
        }
        .padding(18)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
    }

    private var sessionsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Sessions")
                    .font(.title3.weight(.semibold))
                Text("\(sessions.count)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            if sessions.isEmpty {
                Text("No agents have worked in this project yet.")
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 12)
            } else {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 260), spacing: 12)], spacing: 12) {
                    ForEach(sessions) { session in
                        Button {
                            openSession(session.id)
                        } label: {
                            ProjectSessionCard(session: session, gitService: store.gitService)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
    }

    private var worktreesSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Worktrees")
                .font(.title3.weight(.semibold))
            ForEach(sessions.filter { $0.worktree != nil }) { session in
                HStack(spacing: 10) {
                    Image(systemName: "arrow.triangle.branch")
                        .foregroundStyle(.secondary)
                    Text(session.worktree?.branchName ?? "")
                        .font(.callout.monospaced())
                    Spacer()
                    Text(session.worktree?.worktreePath.path ?? "")
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                .padding(11)
                .background(.background, in: RoundedRectangle(cornerRadius: 9))
            }
            if sessions.allSatisfy({ $0.worktree == nil }) {
                Text("No isolated worktrees yet.")
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func launch() {
        let trimmedGoal = goal.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedGoal.isEmpty else { return }
        isLaunching = true
        Task {
            await store.createSession(
                title: String(trimmedGoal.prefix(60)),
                goal: trimmedGoal,
                agent: agent,
                model: model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : model,
                effort: agent.supportsEffortSelection ? effort : nil,
                projectFolder: project.rootPath,
                checkoutMode: useWorktree ? .newWorktree : .mainCheckout
            )
            isLaunching = false
            if store.lastCreationError == nil, let id = store.selectedSessionID {
                goal = ""
                openSession(id)
            }
        }
    }
}

private struct ProjectSessionCard: View {
    let session: Session
    let gitService: any GitServiceProtocol

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Circle()
                    .fill(StatusPresentation.color(for: session.status))
                    .frame(width: 7, height: 7)
                Text(StatusPresentation.label(for: session.status))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                SessionDiffStatView(session: session, gitService: gitService)
                Text(session.agent.displayName)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Text(session.title)
                .font(.headline)
                .foregroundStyle(.primary)
                .lineLimit(1)
            Text(session.goal)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .frame(minHeight: 30, alignment: .top)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.background, in: RoundedRectangle(cornerRadius: 11))
        .overlay { RoundedRectangle(cornerRadius: 11).strokeBorder(.separator.opacity(0.7)) }
    }
}

private struct ProjectPathSheet: View {
    @Environment(\.dismiss) private var dismiss

    let importsWorkspace: Bool
    let addPaths: ([URL]) -> Void
    @State private var path = ""

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: importsWorkspace ? "square.stack.3d.down.right" : "folder.badge.plus")
                    .font(.system(size: 24, weight: .medium))
                    .foregroundStyle(FlotillaPalette.ocean)
                    .frame(width: 40, height: 40)
                    .background(FlotillaPalette.ocean.opacity(0.12), in: RoundedRectangle(cornerRadius: 7))
                VStack(alignment: .leading, spacing: 3) {
                    Text(importsWorkspace ? "Import a workspace" : "Add a project")
                        .font(.title3.weight(.semibold))
                    Text(importsWorkspace
                         ? "Scan one folder for local Git projects and add them together."
                         : "Add a local checkout to your Flotilla project library.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }
            .padding(20)

            Divider()

            VStack(alignment: .leading, spacing: 8) {
                Text(importsWorkspace ? "Workspace path" : "Path")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                HStack(spacing: 8) {
                    TextField(importsWorkspace ? "/path/to/workspace" : "/path/to/project", text: $path)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(.body, design: .monospaced))
                    Button("Browse…", action: browse)
                }
                if importsWorkspace {
                    Text("Immediate child folders containing a .git directory or file will be imported.")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
            }
            .padding(20)

            Divider()

            HStack {
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Button(importsWorkspace ? "Scan" : "Add Project") {
                    addPaths(resolvedPaths)
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(path.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || resolvedPaths.isEmpty)
            }
            .padding(16)
        }
        .frame(width: 520)
        .background(FlotillaPalette.panel)
    }

    private var resolvedPaths: [URL] {
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }
        let root = URL(fileURLWithPath: trimmed).standardizedFileURL
        guard importsWorkspace else { return [root] }
        fileScanLog.notice("resolvedPaths: listing immediate children of \(root.path, privacy: .public)")
        guard let children = try? FileManager.default.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }
        return children.filter { child in
            // Never stat inside a TCC-protected system folder (Desktop,
            // Downloads, Music, Pictures, Movies, Documents) — doing so
            // triggers a macOS "Allow access" prompt even for a plain
            // existence check, and this runs on every keystroke while
            // typing a workspace path (see `.disabled` above), so a
            // home-directory-ish path must not silently probe into them.
            guard !WorkspaceFileService.isTCCProtected(child) else { return false }
            var isDirectory: ObjCBool = false
            let gitPath = child.appendingPathComponent(".git").path
            return FileManager.default.fileExists(atPath: child.path, isDirectory: &isDirectory)
                && isDirectory.boolValue
                && FileManager.default.fileExists(atPath: gitPath)
        }
    }

    private func browse() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = importsWorkspace ? "Choose Workspace" : "Choose Project"
        if panel.runModal() == .OK, let url = panel.url { path = url.path }
    }
}

import SwiftUI
import SessionKit
import DesignSystem
import SettingsKit

struct HomeDashboardView: View {
    @Bindable var store: AppStore
    let openProject: (UUID) -> Void
    let openSession: (UUID) -> Void

    @State private var goal = ""
    @State private var selectedProjectID: UUID?
    @State private var agent: AgentKind = .claudeCode
    @State private var model = ""
    @State private var effort: AgentEffort = .medium
    @State private var useWorktree = true
    @State private var isLaunching = false
    @State private var openCodeSubscription: OpenCodeSubscription = .none

    init(
        store: AppStore,
        openProject: @escaping (UUID) -> Void,
        openSession: @escaping (UUID) -> Void,
        openCodeSubscription: OpenCodeSubscription = .none,
        defaultAgent: AgentKind = .claudeCode
    ) {
        self.store = store
        self.openProject = openProject
        self.openSession = openSession
        self.openCodeSubscription = openCodeSubscription
        _agent = State(initialValue: defaultAgent)
    }

    private var selectedProject: Project? {
        store.projects.first { $0.id == selectedProjectID }
    }

    private var canLaunch: Bool {
        !goal.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !isLaunching
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 34) {
                Spacer(minLength: 54)
                hero
                goalComposer
                recentProjects
                recentSessions
                Spacer(minLength: 36)
            }
            .frame(maxWidth: 920)
            .padding(.horizontal, 32)
            .frame(maxWidth: .infinity)
        }
        .background {
            LinearGradient(
                colors: [FlotillaColors().accent.opacity(0.06), .clear, FlotillaColors().statusWorking.opacity(0.025)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        }
    }

    private var hero: some View {
        VStack(spacing: 10) {
            Image(systemName: "point.3.connected.trianglepath.dotted")
                .font(.system(size: 38, weight: .light))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(FlotillaColors().accent)
                .accessibilityHidden(true)
            Text("What should an agent build?")
                .font(.largeTitle.weight(.semibold))
            Text("Choose a context, describe the outcome, and keep every agent visible while it works.")
                .font(.title3)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
    }

    private var goalComposer: some View {
        VStack(spacing: 0) {
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

            Divider()

            if let error = store.lastCreationError {
                FlotillaBanner.error(error) {
                    store.lastCreationError = nil
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
            }

            HStack(spacing: 10) {
                Menu {
                    Button {
                        selectedProjectID = nil
                    } label: {
                        Label("General session", systemImage: "sparkles")
                    }
                    Divider()
                    ForEach(store.projects) { project in
                        Button(project.name) { selectedProjectID = project.id }
                    }
                } label: {
                    Label(selectedProject?.name ?? "General", systemImage: selectedProject == nil ? "sparkles" : "folder")
                }

                Picker("Agent", selection: $agent) {
                    ForEach(AgentKind.allCases) { kind in
                        Text(kind.displayName).tag(kind)
                    }
                }
                .labelsHidden()
                .frame(width: 126)

                ModelPickerView(agent: agent, openCodeSubscription: openCodeSubscription, model: $model)

                EffortGaugePicker(agent: agent, effort: $effort)

                if selectedProject != nil {
                    Toggle(isOn: $useWorktree) {
                        Label("Worktree", systemImage: "arrow.triangle.branch")
                    }
                    .toggleStyle(.button)
                    .help("Launch in a new isolated worktree")
                }

                Spacer()

                if isLaunching { ProgressView().controlSize(.small) }
                Button("Start Session", action: launch)
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .disabled(!canLaunch)
                    .keyboardShortcut(.return, modifiers: [.command])
            }
            .padding(12)
        }
        .background(.regularMaterial)
        .compositingGroup()
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(Color(nsColor: .separatorColor).opacity(0.7))
        }
        .shadow(color: .black.opacity(0.08), radius: 22, y: 10)
    }

    private var recentProjects: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Recent projects")
                    .font(.headline)
                Spacer()
                Button("View all") {
                    if let first = store.projects.first { openProject(first.id) }
                }
                .buttonStyle(.plain)
                .foregroundStyle(.tint)
                .disabled(store.projects.isEmpty)
            }
            if store.projects.isEmpty {
                Text("Projects appear here as soon as you launch a project-scoped session.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(18)
                    .background(.background, in: RoundedRectangle(cornerRadius: 12))
            } else {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 210), spacing: 12)], spacing: 12) {
                    ForEach(store.projects.prefix(4)) { project in
                        Button {
                            openProject(project.id)
                        } label: {
                            ProjectCompactCard(project: project, sessionCount: store.sessions(for: project).count)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
    }

    private var recentSessions: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Recent sessions")
                .font(.headline)
            if store.sessions.isEmpty {
                Text("No sessions yet.")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(store.sessions.sorted { $0.lastActiveAt > $1.lastActiveAt }.prefix(4)) { session in
                    Button {
                        openSession(session.id)
                    } label: {
                        HStack(spacing: 10) {
                            StatusBadge(session.status, variant: .compact)
                            Text(session.title)
                                .foregroundStyle(.primary)
                                .lineLimit(1)
                            Spacer()
                            Text(session.agent.displayName)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Image(systemName: "chevron.right")
                                .font(.caption)
                                .foregroundStyle(.tertiary)
                        }
                        .padding(.horizontal, 13)
                        .padding(.vertical, 10)
                        .background(.background, in: RoundedRectangle(cornerRadius: 10))
                    }
                    .buttonStyle(.plain)
                }
            }
        }
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
                checkoutMode: useWorktree && selectedProject != nil ? .newWorktree : .mainCheckout
            )
            isLaunching = false
            if store.lastCreationError == nil,
               let created = store.sessions.first(where: { !previousIDs.contains($0.id) }) {
                goal = ""
                openSession(created.id)
            }
        }
    }
}

struct ProjectCompactCard: View {
    let project: Project
    let sessionCount: Int

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                ZStack {
                    RoundedRectangle(cornerRadius: 6)
                        .fill(FlotillaColors().accent.opacity(0.12))
                    Image(systemName: "folder.fill")
                        .foregroundStyle(FlotillaColors().accent)
                }
                .frame(width: 32, height: 32)
                Spacer()
                Image(systemName: "ellipsis")
                    .foregroundStyle(.secondary)
            }
            Text(project.name)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(.primary)
                .lineLimit(1)
            Text(project.rootPath.path)
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
            Divider()
            HStack {
                Label("\(sessionCount) session\(sessionCount == 1 ? "" : "s")", systemImage: "terminal")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Text(sessionCount > 0 ? "Active" : "Ready")
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(sessionCount > 0 ? FlotillaColors().statusWorking : .secondary)
            }
        }
        .padding(15)
        .frame(maxWidth: .infinity, minHeight: 154, alignment: .leading)
        .background(FlotillaColors().surface, in: RoundedRectangle(cornerRadius: 8))
        .overlay {
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(FlotillaColors().separator)
        }
        .contentShape(.rect)
    }
}

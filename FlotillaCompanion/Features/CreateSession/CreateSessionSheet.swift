import SwiftUI
import SessionKit
import DesignSystem

/// Same fields and defaults as the Mac's create-session flow.
struct CreateSessionSheet: View {
    let macID: MacHost.ID
    let onCreated: (CompanionSession.ID) -> Void

    @Environment(CompanionStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @FocusState private var isGoalFocused: Bool

    @State private var goal = ""
    @State private var projectID: UUID?
    @State private var agent: AgentKind = .claudeCode
    @State private var model = ""
    @State private var effort: AgentEffort?
    @State private var createWorktree = true
    @State private var fetchFirst = true
    @State private var subscription: OpenCodeSubscription = .none
    @State private var isCreating = false

    var body: some View {
        let catalog = store.catalog(on: macID)
        NavigationStack {
            Form {
                Section("Goal") {
                    TextField("What should the agent do?", text: $goal, axis: .vertical)
                        .lineLimit(3...8)
                        .focused($isGoalFocused)
                }

                Section("Project") {
                    Picker("Project", selection: $projectID) {
                        Text("General").tag(UUID?.none)
                        ForEach(store.projects(on: macID)) { project in
                            Text(project.name).tag(Optional(project.id))
                        }
                    }
                }

                AgentModelEffortControls(agent: $agent, model: $model, effort: $effort, catalog: catalog)

                if projectID != nil {
                    Section {
                        Toggle("Create worktree", isOn: $createWorktree.animation())
                        if createWorktree {
                            Toggle("Fetch first", isOn: $fetchFirst)
                        }
                    } footer: {
                        Text("A worktree isolates the session on its own branch.")
                    }
                }

                if agent == .openCode {
                    Section("OpenCode") {
                        Picker("Subscription", selection: $subscription) {
                            ForEach(OpenCodeSubscription.allCases) { Text($0.displayName).tag($0) }
                        }
                    }
                }
            }
            .tint(FlotillaColors.accent)
            .navigationTitle("New Session")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", systemImage: "xmark") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Create", systemImage: "arrow.up") { create() }
                        .buttonStyle(.glassProminent)
                        .tint(FlotillaColors.accent)
                        .disabled(isCreating || !store.isActionable(macID: macID))
                }
            }
            .onAppear {
                isGoalFocused = true
                applyRememberedChoice(for: projectID)
            }
            .onChange(of: projectID) { _, newValue in
                applyRememberedChoice(for: newValue)
            }
        }
        .presentationDetents([.large])
    }

    private func applyRememberedChoice(for project: UUID?) {
        if let choice = store.rememberedChoice(for: project) {
            agent = choice.agent
            model = choice.model
            effort = choice.effort
        } else if model.isEmpty {
            let entry = store.catalog(on: macID).entry(for: agent)
            model = entry.defaultModel
            effort = entry.defaultEffort
        }
    }

    private func create() {
        isCreating = true
        let request = NewSessionRequest(
            goal: goal.trimmingCharacters(in: .whitespacesAndNewlines),
            projectID: projectID,
            agent: agent,
            model: model,
            effort: agent.supportsEffortSelection ? effort : nil,
            createWorktree: projectID != nil && createWorktree,
            fetchFirst: fetchFirst,
            openCodeSubscription: subscription
        )
        Task {
            if let id = await store.createSession(request, on: macID) {
                dismiss()
                onCreated(id)
            }
            isCreating = false
        }
    }
}

/// Moves a session to another agent, carrying its conversation.
struct HandoffSheet: View {
    let session: CompanionSession
    let macID: MacHost.ID

    @Environment(CompanionStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State private var agent: AgentKind
    @State private var model = ""
    @State private var effort: AgentEffort?
    @State private var note = ""
    @State private var isConfirming = false

    init(session: CompanionSession, macID: MacHost.ID) {
        self.session = session
        self.macID = macID
        let target = AgentKind.allCases.first { $0 != session.agent } ?? .claudeCode
        _agent = State(initialValue: target)
        let entry = AgentCatalog.fallback.entry(for: target)
        _model = State(initialValue: entry.defaultModel)
        _effort = State(initialValue: entry.defaultEffort)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    HStack(spacing: 10) {
                        ProviderLogo(agent: session.agent).frame(width: 20, height: 20)
                        Image(systemName: "arrow.right").foregroundStyle(FlotillaColors.textTertiary)
                        ProviderLogo(agent: agent).frame(width: 20, height: 20)
                        Text("\(session.agent.displayName) → \(agent.displayName)")
                            .font(.subheadline)
                    }
                } footer: {
                    Text("The conversation moves to the new agent. The session keeps its project and worktree.")
                }

                AgentModelEffortControls(
                    agent: $agent, model: $model, effort: $effort,
                    catalog: store.catalog(on: macID),
                    agents: AgentKind.allCases.filter { $0 != session.agent }
                )

                Section("Reason (optional)") {
                    TextField("Why hand off?", text: $note, axis: .vertical)
                        .lineLimit(2...4)
                }
            }
            .tint(FlotillaColors.accent)
            .navigationTitle("Hand Off")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", systemImage: "xmark") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Hand Off") { isConfirming = true }
                        .buttonStyle(.glassProminent)
                        .tint(FlotillaColors.accent)
                        .disabled(!store.isActionable(sessionID: session.id))
                }
            }
            .confirmationDialog("Hand off to \(agent.displayName)?", isPresented: $isConfirming, titleVisibility: .visible) {
                Button("Hand Off") {
                    Task {
                        await store.handoff(session.id, HandoffRequest(agent: agent, model: model, effort: effort, note: note))
                        dismiss()
                    }
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("\(session.agent.displayName) stops and \(agent.displayName) continues from the same conversation.")
            }
        }
        .presentationDetents([.large])
    }
}

#Preview("Create") {
    CreateSessionSheet(macID: MockFixtures.MacID.studio) { _ in }
        .environment(CompanionStore(data: MockCompanionDataSource()))
        .preferredColorScheme(.dark)
}

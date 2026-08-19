import SwiftUI
import AppKit
import SessionKit
import DesignSystem

/// Skills tab for a project workspace.
///
/// Discovers and organizes skills across global locations (~/.claude/skills, ~/.agents/skills,
/// ~/.codex/skills, plugins) and project-scoped roots. Features rendered markdown view and
/// syntax-highlighted editor with ⌘S save.
struct ProjectSkillsView: View {
    let project: Project
    @Bindable var store: AppStore

    @State private var viewModel: ProjectSkillsViewModel
    @State private var isEditing = false
    @FocusState private var isEditorFocused: Bool

    init(
        project: Project,
        store: AppStore,
        service: any WorkspaceFileServicing = WorkspaceFileService()
    ) {
        self.project = project
        self.store = store
        self._viewModel = State(initialValue: ProjectSkillsViewModel(projectRoot: project.rootPath, service: service))
    }

    var body: some View {
        HSplitView {
            skillList
                .frame(minWidth: 260, idealWidth: 320, maxWidth: 420)
            skillDetail
                .frame(minWidth: 400)
        }
        .task(id: project.id) {
            await viewModel.load()
        }
    }

    // MARK: - Skills List

    private var filteredSkills: [SkillEntry] {
        switch viewModel.filter {
        case .all: viewModel.skills
        case .global: viewModel.skills.filter { $0.scope == .global }
        case .project: viewModel.skills.filter { $0.scope == .project }
        }
    }

    private var skillList: some View {
        VStack(spacing: 0) {
            // Header with filter & refresh
            VStack(spacing: FlotillaSpacing.small) {
                HStack(spacing: FlotillaSpacing.small) {
                    Text("Skills")
                        .font(.headline)
                    Spacer()
                    Button {
                        Task { await viewModel.load() }
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .buttonStyle(.plain)
                    .help("Refresh skills")
                }

                Picker("Scope", selection: $viewModel.filter) {
                    Text("All").tag(SkillsFilter.all)
                    Text("Global").tag(SkillsFilter.global)
                    Text("Project").tag(SkillsFilter.project)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
            }
            .padding(.horizontal, FlotillaSpacing.medium)
            .padding(.vertical, FlotillaSpacing.small)
            .background(FlotillaColors.surface)

            Divider()

            if viewModel.isLoading && viewModel.skills.isEmpty {
                ProgressView("Scanning skills…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(FlotillaColors.surface)
            } else if filteredSkills.isEmpty {
                ContentUnavailableView(
                    "No Skills Found",
                    systemImage: "sparkles",
                    description: Text(emptyDescription)
                )
                .background(FlotillaColors.surface)
            } else {
                List(filteredSkills, selection: $viewModel.selectedSkill) { skill in
                    Button {
                        isEditing = false
                        Task { await viewModel.select(skill) }
                    } label: {
                        skillRow(skill)
                    }
                    .buttonStyle(.plain)
                    .listRowBackground(
                        RoundedRectangle(cornerRadius: FlotillaRadius.control, style: .continuous)
                            .fill(viewModel.selectedSkill == skill ? FlotillaColors.accent.opacity(0.09) : .clear)
                    )
                }
                .scrollContentBackground(.hidden)
                .background(FlotillaColors.surface)
            }
        }
        .background(FlotillaColors.surface)
    }

    private func skillRow(_ skill: SkillEntry) -> some View {
        HStack(alignment: .top, spacing: FlotillaSpacing.small) {
            Image(systemName: skill.source != nil ? "puzzlepiece.extension" : "sparkles")
                .font(.system(size: FlotillaIconSize.small))
                .foregroundStyle(FlotillaColors.accent)
                .padding(.top, 2)

            VStack(alignment: .leading, spacing: 3) {
                HStack {
                    Text(skill.name)
                        .font(FlotillaTypography.body.weight(.medium))
                        .foregroundStyle(FlotillaColors.textPrimary)
                        .lineLimit(1)
                    Spacer()
                    scopeBadge(skill.scope, source: skill.source)
                }

                if !skill.description.isEmpty {
                    Text(skill.description)
                        .font(FlotillaTypography.caption)
                        .foregroundStyle(FlotillaColors.textTertiary)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .padding(.vertical, 3)
    }

    @ViewBuilder
    private func scopeBadge(_ scope: SkillScope, source: String? = nil) -> some View {
        HStack(spacing: 3) {
            Image(systemName: scope == .global ? "globe" : "folder")
                .font(.system(size: 8))
            Text(source ?? (scope == .global ? "global" : "project"))
                .font(FlotillaTypography.caption2)
                .lineLimit(1)
        }
        .foregroundStyle(FlotillaColors.textTertiary)
        .padding(.horizontal, 5)
        .padding(.vertical, 1)
        .background(FlotillaColors.surfaceElevated, in: Capsule())
    }

    private var emptyDescription: String {
        switch viewModel.filter {
        case .all: return "Add SKILL.md to .claude/skills/, .agents/skills/, or .codex/skills/ (globally or in this project)."
        case .global: return "No global skills found in ~/.claude/skills/, ~/.agents/skills/, or ~/.codex/skills/."
        case .project: return "No project-scoped skills found in .claude/skills/, .agents/skills/, or .codex/skills/."
        }
    }

    // MARK: - Skill Detail & Editor

    @ViewBuilder
    private var skillDetail: some View {
        if let skill = viewModel.selectedSkill {
            VStack(alignment: .leading, spacing: 0) {
                detailHeader(skill)
                Divider()

                if isEditing {
                    SyntaxHighlightedTextEditor(
                        text: $viewModel.content,
                        language: .markdown,
                        font: .system(.body, design: .monospaced),
                        onTextChange: { newValue in
                            viewModel.content = newValue
                        }
                    )
                    .focused($isEditorFocused)
                    .padding(FlotillaSpacing.small)
                    .background(FlotillaColors.terminalCanvas)
                } else {
                    ScrollView {
                        MarkdownView(markdown: viewModel.content)
                            .padding(FlotillaSpacing.large)
                    }
                    .background(FlotillaColors.canvas)
                }
            }
        } else {
            ContentUnavailableView(
                "Select a Skill",
                systemImage: "sparkles",
                description: Text("Choose a skill from the list to view its instructions and documentation.")
            )
            .background(FlotillaColors.canvas)
        }
    }

    private func detailHeader(_ skill: SkillEntry) -> some View {
        VStack(alignment: .leading, spacing: FlotillaSpacing.small) {
            HStack(alignment: .center, spacing: FlotillaSpacing.small) {
                Image(systemName: skill.source != nil ? "puzzlepiece.extension.fill" : "sparkles")
                    .font(.system(size: FlotillaIconSize.large))
                    .foregroundStyle(FlotillaColors.accent)

                VStack(alignment: .leading, spacing: 2) {
                    Text(skill.name)
                        .font(FlotillaTypography.headline)
                        .foregroundStyle(FlotillaColors.textPrimary)
                    if !skill.description.isEmpty {
                        Text(skill.description)
                            .font(FlotillaTypography.callout)
                            .foregroundStyle(FlotillaColors.textSecondary)
                    }
                }

                Spacer()

                scopeBadge(skill.scope, source: skill.source)

                if isEditing {
                    if let message = viewModel.message {
                        Label(
                            message,
                            systemImage: message.hasPrefix("Saved") ? "checkmark.circle.fill" : "exclamationmark.triangle.fill"
                        )
                        .font(.caption)
                        .foregroundStyle(message.hasPrefix("Saved") ? FlotillaColors.success : Color.red)
                    }

                    Button("Save") {
                        isEditorFocused = false
                        Task {
                            await Task.yield()
                            await viewModel.save()
                        }
                    }
                    .keyboardShortcut("s", modifiers: .command)
                    .disabled(viewModel.isSaving)

                    Button("Done") {
                        isEditing = false
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                } else {
                    Button {
                        isEditing = true
                    } label: {
                        Label("Edit", systemImage: "pencil")
                            .font(FlotillaTypography.caption)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
            }
            .padding(.horizontal, FlotillaSpacing.large)
            .padding(.vertical, FlotillaSpacing.medium)
        }
        .background(FlotillaColors.surface)
    }
}

// MARK: - Filter & ViewModel

enum SkillsFilter: String, Sendable {
    case all, global, project
}

@Observable
@MainActor
final class ProjectSkillsViewModel {
    private let projectRoot: URL
    private let service: any WorkspaceFileServicing

    private(set) var skills: [SkillEntry] = []
    var selectedSkill: SkillEntry?
    var content = ""
    var savedAt: Date?
    var filter: SkillsFilter = .all
    private(set) var isLoading = false
    private(set) var isSaving = false
    private(set) var message: String?

    init(projectRoot: URL, service: any WorkspaceFileServicing = WorkspaceFileService()) {
        self.projectRoot = projectRoot
        self.service = service
    }

    func load() async {
        isLoading = true
        defer { isLoading = false }
        do {
            skills = try await service.skills(projectRoot: projectRoot)
            message = nil
            if selectedSkill == nil || !skills.contains(where: { $0.id == selectedSkill?.id }) {
                if let first = skills.first {
                    await select(first)
                }
            }
        } catch {
            skills = []
            message = error.localizedDescription
        }
    }

    func select(_ skill: SkillEntry) async {
        selectedSkill = skill
        do {
            content = try await service.readText(at: skill.url)
            let fileManager = FileManager.default
            if let attributes = try? fileManager.attributesOfItem(atPath: skill.url.path),
               let modificationDate = attributes[.modificationDate] as? Date {
                savedAt = modificationDate
            }
            message = nil
        } catch {
            message = "Could not open \(skill.name): \(error.localizedDescription)"
        }
    }

    func save() async {
        guard let selectedSkill else { return }

        let fileManager = FileManager.default
        let currentAttributes = try? fileManager.attributesOfItem(atPath: selectedSkill.url.path)
        let currentModificationDate = currentAttributes?[.modificationDate] as? Date

        if let savedAt, let currentModificationDate,
           currentModificationDate > savedAt
        {
            message = "File was modified outside this app — changes may be lost"
            isSaving = false
            return
        }

        isSaving = true
        defer { isSaving = false }
        do {
            try await service.writeText(content, to: selectedSkill.url)
            savedAt = Date()
            message = "Saved"
        } catch {
            message = "Could not save: \(error.localizedDescription)"
        }
    }
}

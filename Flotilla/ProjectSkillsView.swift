import SwiftUI
import AppKit
import SessionKit
import DesignSystem

/// Skills tab for a project workspace.
///
/// Features a responsive card grid showing all discovered global, project, and plugin skills.
/// Clicking a card opens an enlarged skill view with rendered Markdown documentation
/// and an interactive in-place editor with ⌘S save bridge.
struct ProjectSkillsView: View {
    let project: Project
    @Bindable var store: AppStore

    @State private var viewModel: ProjectSkillsViewModel
    @State private var searchText = ""
    @State private var enlargedSkill: SkillEntry?
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
        ZStack {
            VStack(spacing: 0) {
                headerBar
                Divider()

                ScrollView {
                    if viewModel.isLoading && viewModel.skills.isEmpty {
                        ProgressView("Scanning skills…")
                            .frame(maxWidth: .infinity, minHeight: 300)
                    } else if filteredSkills.isEmpty {
                        emptyStateView
                            .frame(maxWidth: .infinity, minHeight: 320)
                    } else {
                        skillsGrid
                            .padding(FlotillaSpacing.large)
                    }
                }
                .background(FlotillaColors.canvas)
            }

            // Enlarged Skill Card Modal
            if let skill = enlargedSkill {
                enlargedCardOverlay(for: skill)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .task(id: project.id) {
            await viewModel.load()
        }
    }

    // MARK: - Header Bar

    private var headerBar: some View {
        HStack(spacing: FlotillaSpacing.medium) {
            HStack(spacing: FlotillaSpacing.small) {
                Text("Skills")
                    .font(FlotillaTypography.headline)
                    .foregroundStyle(FlotillaColors.textPrimary)

                Text("\(filteredSkills.count)")
                    .font(FlotillaTypography.caption2.monospaced())
                    .foregroundStyle(FlotillaColors.textTertiary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(FlotillaColors.surfaceElevated, in: Capsule())
            }

            Spacer()

            // Search Bar
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(FlotillaColors.textTertiary)
                    .font(.system(size: FlotillaIconSize.small))
                TextField("Search skills…", text: $searchText)
                    .textFieldStyle(.plain)
                    .font(FlotillaTypography.caption)
                if !searchText.isEmpty {
                    Button {
                        searchText = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(FlotillaColors.textTertiary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, FlotillaSpacing.small + 2)
            .padding(.vertical, 5)
            .background(FlotillaColors.surfaceElevated, in: RoundedRectangle(cornerRadius: FlotillaRadius.control))
            .frame(width: 220)

            // Scope Picker
            Picker("Scope", selection: $viewModel.filter) {
                Text("All").tag(SkillsFilter.all)
                Text("Global").tag(SkillsFilter.global)
                Text("Project").tag(SkillsFilter.project)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 200)

            Button {
                Task { await viewModel.load() }
            } label: {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: FlotillaIconSize.small))
            }
            .buttonStyle(.plain)
            .help("Refresh skills")
        }
        .padding(.horizontal, FlotillaSpacing.large)
        .padding(.vertical, FlotillaSpacing.small + 2)
        .background(FlotillaColors.surface)
    }

    // MARK: - Skills Grid

    private var filteredSkills: [SkillEntry] {
        let base: [SkillEntry] = switch viewModel.filter {
        case .all: viewModel.skills
        case .global: viewModel.skills.filter { $0.scope == .global }
        case .project: viewModel.skills.filter { $0.scope == .project }
        }

        guard !searchText.isEmpty else { return base }
        return base.filter {
            $0.name.localizedCaseInsensitiveContains(searchText) ||
            $0.description.localizedCaseInsensitiveContains(searchText) ||
            ($0.source?.localizedCaseInsensitiveContains(searchText) ?? false)
        }
    }

    private var skillsGrid: some View {
        LazyVGrid(
            columns: [GridItem(.adaptive(minimum: 280, maximum: 380), spacing: FlotillaSpacing.medium)],
            spacing: FlotillaSpacing.medium
        ) {
            ForEach(filteredSkills) { skill in
                SkillCardView(skill: skill) {
                    openSkill(skill)
                }
            }
        }
    }

    private func openSkill(_ skill: SkillEntry) {
        isEditing = false
        Task {
            await viewModel.select(skill)
            withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) {
                enlargedSkill = skill
            }
        }
    }

    private func closeSkill() {
        withAnimation(.easeOut(duration: 0.2)) {
            enlargedSkill = nil
            isEditing = false
        }
    }

    // MARK: - Enlarged Card Overlay

    private func enlargedCardOverlay(for skill: SkillEntry) -> some View {
        ZStack {
            // Backdrop
            Color.black.opacity(0.55)
                .ignoresSafeArea()
                .onTapGesture {
                    closeSkill()
                }

            // Floating Card
            VStack(spacing: 0) {
                enlargedCardHeader(skill)
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
                            .padding(FlotillaSpacing.large + 4)
                    }
                    .background(FlotillaColors.canvas)
                }
            }
            .frame(minWidth: 540, idealWidth: 720, maxWidth: 840, minHeight: 460, idealHeight: 620, maxHeight: 760)
            .background(FlotillaColors.surface)
            .clipShape(RoundedRectangle(cornerRadius: FlotillaRadius.card + 4, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: FlotillaRadius.card + 4, style: .continuous)
                    .strokeBorder(FlotillaColors.separator.opacity(0.8), lineWidth: 1)
            }
            .shadow(color: Color.black.opacity(0.4), radius: 24, x: 0, y: 12)
            .padding(FlotillaSpacing.large)
            .transition(.scale(scale: 0.95).combined(with: .opacity))
        }
    }

    private func enlargedCardHeader(_ skill: SkillEntry) -> some View {
        VStack(alignment: .leading, spacing: FlotillaSpacing.small) {
            HStack(alignment: .top, spacing: FlotillaSpacing.medium) {
                // Large Icon
                ZStack {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(FlotillaColors.accent.opacity(0.14))
                        .frame(width: 44, height: 44)
                    Image(systemName: skill.source != nil ? "puzzlepiece.extension.fill" : "sparkles")
                        .font(.system(size: 20))
                        .foregroundStyle(FlotillaColors.accent)
                }

                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 8) {
                        Text(skill.name)
                            .font(.title3.weight(.bold))
                            .foregroundStyle(FlotillaColors.textPrimary)

                        scopeBadge(skill.scope, source: skill.source)
                    }

                    if !skill.description.isEmpty {
                        Text(skill.description)
                            .font(FlotillaTypography.callout)
                            .foregroundStyle(FlotillaColors.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }

                Spacer()

                // Actions
                HStack(spacing: FlotillaSpacing.small) {
                    if isEditing {
                        if let message = viewModel.message {
                            Label(
                                message,
                                systemImage: message.hasPrefix("Saved") ? "checkmark.circle.fill" : "exclamationmark.triangle.fill"
                            )
                            .font(FlotillaTypography.caption2)
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

                    Button {
                        closeSkill()
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 16))
                            .foregroundStyle(FlotillaColors.textTertiary)
                    }
                    .buttonStyle(.plain)
                    .help("Close (Esc)")
                    .keyboardShortcut(.cancelAction)
                }
            }
        }
        .padding(.horizontal, FlotillaSpacing.large)
        .padding(.vertical, FlotillaSpacing.medium)
        .background(FlotillaColors.surface)
    }

    @ViewBuilder
    private func scopeBadge(_ scope: SkillScope, source: String? = nil) -> some View {
        HStack(spacing: 4) {
            Image(systemName: scope == .global ? "globe" : "folder")
                .font(.system(size: 9))
            Text(source ?? (scope == .global ? "global" : "project"))
                .font(FlotillaTypography.caption2.weight(.medium))
                .lineLimit(1)
        }
        .foregroundStyle(FlotillaColors.textSecondary)
        .padding(.horizontal, 7)
        .padding(.vertical, 2)
        .background(FlotillaColors.surfaceElevated, in: Capsule())
    }

    private var emptyStateView: some View {
        ContentUnavailableView(
            "No Skills Found",
            systemImage: "sparkles",
            description: Text(emptyDescription)
        )
    }

    private var emptyDescription: String {
        switch viewModel.filter {
        case .all: return "Add SKILL.md to .claude/skills/, .agents/skills/, or .codex/skills/ (globally or in this project)."
        case .global: return "No global skills found in ~/.claude/skills/, ~/.agents/skills/, or ~/.codex/skills/."
        case .project: return "No project-scoped skills found in .claude/skills/, .agents/skills/, or .codex/skills/."
        }
    }
}

// MARK: - Skill Card View

struct SkillCardView: View {
    let skill: SkillEntry
    let action: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: FlotillaSpacing.medium) {
                // Top Row: Icon + Scope Pill
                HStack(alignment: .center) {
                    ZStack {
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(FlotillaColors.accent.opacity(isHovered ? 0.18 : 0.10))
                            .frame(width: 32, height: 32)
                        Image(systemName: skill.source != nil ? "puzzlepiece.extension.fill" : "sparkles")
                            .font(.system(size: 14))
                            .foregroundStyle(FlotillaColors.accent)
                    }

                    Spacer()

                    scopeBadge(skill.scope, source: skill.source)
                }

                // Middle: Name & Description
                VStack(alignment: .leading, spacing: 4) {
                    Text(skill.name)
                        .font(FlotillaTypography.headline)
                        .foregroundStyle(FlotillaColors.textPrimary)
                        .lineLimit(1)

                    if !skill.description.isEmpty {
                        Text(skill.description)
                            .font(FlotillaTypography.caption)
                            .foregroundStyle(FlotillaColors.textSecondary)
                            .lineLimit(3)
                            .fixedSize(horizontal: false, vertical: true)
                    } else {
                        Text("No description provided.")
                            .font(FlotillaTypography.caption)
                            .foregroundStyle(FlotillaColors.textTertiary)
                            .italic()
                    }
                }
                .frame(minHeight: 52, alignment: .topLeading)

                Divider()
                    .opacity(0.5)

                // Bottom Row: Action hint
                HStack {
                    Text(skill.url.deletingLastPathComponent().lastPathComponent)
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(FlotillaColors.textTertiary)
                        .lineLimit(1)

                    Spacer()

                    HStack(spacing: 3) {
                        Text("Open")
                            .font(FlotillaTypography.caption2.weight(.medium))
                        Image(systemName: "arrow.right")
                            .font(.system(size: 9, weight: .bold))
                    }
                    .foregroundStyle(isHovered ? FlotillaColors.accent : FlotillaColors.textTertiary)
                }
            }
            .padding(FlotillaSpacing.medium)
            .background(FlotillaColors.surfaceElevated)
            .clipShape(RoundedRectangle(cornerRadius: FlotillaRadius.card, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: FlotillaRadius.card, style: .continuous)
                    .strokeBorder(
                        isHovered ? FlotillaColors.accent.opacity(0.5) : FlotillaColors.separator.opacity(0.6),
                        lineWidth: 1
                    )
            }
            .shadow(color: Color.black.opacity(isHovered ? 0.2 : 0.05), radius: isHovered ? 8 : 2, y: isHovered ? 4 : 1)
            .scaleEffect(isHovered ? 1.01 : 1.0)
            .animation(.easeInOut(duration: 0.16), value: isHovered)
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            isHovered = hovering
        }
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
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .background(FlotillaColors.surface, in: Capsule())
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

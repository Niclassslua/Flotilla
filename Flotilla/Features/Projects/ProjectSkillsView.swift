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
        return base.filter { skill in
            skill.name.localizedCaseInsensitiveContains(searchText) ||
            skill.description.localizedCaseInsensitiveContains(searchText) ||
            (skill.source?.localizedCaseInsensitiveContains(searchText) ?? false) ||
            skill.framework.displayName.localizedCaseInsensitiveContains(searchText) ||
            (skill.version?.localizedCaseInsensitiveContains(searchText) ?? false) ||
            (skill.argumentHint?.localizedCaseInsensitiveContains(searchText) ?? false) ||
            skill.tags.contains { $0.localizedCaseInsensitiveContains(searchText) }
        }
    }

    private var skillsGrid: some View {
        LazyVGrid(
            columns: [GridItem(.adaptive(minimum: 300, maximum: 420), spacing: FlotillaSpacing.medium)],
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
            .frame(minWidth: 580, idealWidth: 760, maxWidth: 880, minHeight: 480, idealHeight: 640, maxHeight: 800)
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
        VStack(alignment: .leading, spacing: FlotillaSpacing.small + 2) {
            HStack(alignment: .top, spacing: FlotillaSpacing.medium) {
                // Large Icon
                ZStack {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(AgentBrand.iconBackgroundColor(for: skill.framework, isHovered: false))
                        .frame(width: 44, height: 44)
                    if let logo = skill.framework.logoAssetName {
                        Image(logo)
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                            .frame(width: 24, height: 24)
                    } else {
                        Image(systemName: skill.source != nil ? "puzzlepiece.extension.fill" : skill.framework.iconSystemName)
                            .font(.system(size: 20))
                            .foregroundStyle(AgentBrand.accentColor(for: skill.framework))
                    }
                }

                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 8) {
                        Text(skill.name)
                            .font(.title3.weight(.bold))
                            .foregroundStyle(FlotillaColors.textPrimary)

                        frameworkBadge(skill.framework)
                        scopeBadge(skill.scope, source: skill.source)

                        if let version = skill.version {
                            Text("v\(version)")
                                .font(FlotillaTypography.caption2.monospaced())
                                .foregroundStyle(FlotillaColors.textTertiary)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(FlotillaColors.surfaceElevated, in: Capsule())
                        }
                    }

                    if !skill.description.isEmpty {
                        Text(skill.description)
                            .font(FlotillaTypography.callout)
                            .foregroundStyle(FlotillaColors.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    // Invocation snippet
                    if let hint = skill.argumentHint {
                        HStack(spacing: 6) {
                            Image(systemName: "terminal")
                                .font(.system(size: 10))
                                .foregroundStyle(FlotillaColors.accent)
                            Text("/\(skill.name) \(hint)")
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundStyle(FlotillaColors.textPrimary)

                            Button {
                                let pasteboard = NSPasteboard.general
                                pasteboard.clearContents()
                                pasteboard.setString("/\(skill.name) \(hint)", forType: .string)
                            } label: {
                                Image(systemName: "doc.on.doc")
                                    .font(.system(size: 10))
                                    .foregroundStyle(FlotillaColors.textTertiary)
                            }
                            .buttonStyle(.plain)
                            .help("Copy command invocation")
                        }
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(FlotillaColors.canvas.opacity(0.8), in: RoundedRectangle(cornerRadius: 4))
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

            // Stats ribbon
            HStack(spacing: FlotillaSpacing.medium) {
                if skill.bundleStats.scriptsCount > 0 {
                    bundleMetricPill(
                        label: "\(skill.bundleStats.scriptsCount) script\(skill.bundleStats.scriptsCount == 1 ? "" : "s")",
                        icon: "bolt.fill",
                        color: FlotillaColors.accent
                    )
                }
                if skill.bundleStats.referencesCount > 0 {
                    bundleMetricPill(
                        label: "\(skill.bundleStats.referencesCount) doc\(skill.bundleStats.referencesCount == 1 ? "" : "s")",
                        icon: "doc.text.fill",
                        color: FlotillaColors.statusReady
                    )
                }
                if skill.bundleStats.dataCount > 0 {
                    bundleMetricPill(
                        label: "\(skill.bundleStats.dataCount) data/examples",
                        icon: "tablecells.fill",
                        color: FlotillaColors.statusWorking
                    )
                }

                bundleMetricPill(
                    label: "~\(skill.bundleStats.estimatedReadMinutes) min read",
                    icon: "clock",
                    color: FlotillaColors.textTertiary
                )

                bundleMetricPill(
                    label: "\(skill.bundleStats.lineCount) lines",
                    icon: "text.alignleft",
                    color: FlotillaColors.textTertiary
                )

                if let date = skill.bundleStats.lastModified {
                    bundleMetricPill(
                        label: formatRelativeDate(date),
                        icon: "calendar",
                        color: FlotillaColors.textTertiary
                    )
                }

                Spacer()

                if let author = skill.author {
                    Text("by \(author)")
                        .font(FlotillaTypography.caption2)
                        .foregroundStyle(FlotillaColors.textTertiary)
                }
                if let license = skill.license {
                    Text(license)
                        .font(FlotillaTypography.caption2.monospaced())
                        .foregroundStyle(FlotillaColors.textTertiary)
                        .lineLimit(1)
                }
            }
            .padding(.top, 2)

            // Tags row
            if !skill.tags.isEmpty {
                HStack(spacing: 5) {
                    ForEach(skill.tags, id: \.self) { tag in
                        Text("#\(tag)")
                            .font(FlotillaTypography.caption2)
                            .foregroundStyle(FlotillaColors.textTertiary)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 1.5)
                            .background(FlotillaColors.canvas.opacity(0.6), in: RoundedRectangle(cornerRadius: 3))
                    }
                }
            }
        }
        .padding(.horizontal, FlotillaSpacing.large)
        .padding(.vertical, FlotillaSpacing.medium)
        .background(FlotillaColors.surface)
    }

    @ViewBuilder
    private func bundleMetricPill(label: String, icon: String, color: Color) -> some View {
        HStack(spacing: 4) {
            Image(systemName: icon)
                .font(.system(size: 9))
                .foregroundStyle(color)
            Text(label)
                .font(FlotillaTypography.caption2)
                .foregroundStyle(FlotillaColors.textSecondary)
        }
    }

    @ViewBuilder
    private func frameworkBadge(_ framework: SkillFramework) -> some View {
        Text(framework.displayName)
            .font(FlotillaTypography.caption2.weight(.medium))
            .foregroundStyle(AgentBrand.accentColor(for: framework))
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(AgentBrand.accentColor(for: framework).opacity(0.12), in: Capsule())
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
        case .all: return "Add SKILL.md to .claude/skills/, .agents/skills/, .codex/skills/, .cursor/skills/, or .gemini/skills/ (globally or in this project)."
        case .global: return "No global skills found in ~/.claude/skills/, ~/.agents/skills/, ~/.codex/skills/, ~/.cursor/skills/, or ~/.gemini/skills/."
        case .project: return "No project-scoped skills found in project skills folders."
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
            VStack(alignment: .leading, spacing: 0) {
                // Top Row: Framework Icon + Name Pill + Version + Scope Pill
                HStack(alignment: .center, spacing: FlotillaSpacing.small) {
                    ZStack {
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(AgentBrand.iconBackgroundColor(for: skill.framework, isHovered: isHovered))
                            .frame(width: 32, height: 32)
                            .overlay {
                                RoundedRectangle(cornerRadius: 8, style: .continuous)
                                    .strokeBorder(AgentBrand.accentColor(for: skill.framework).opacity(isHovered ? 0.35 : 0.15), lineWidth: 0.5)
                            }
                        if let logo = skill.framework.logoAssetName {
                            Image(logo)
                                .resizable()
                                .aspectRatio(contentMode: .fit)
                                .frame(width: 17, height: 17)
                        } else {
                            Image(systemName: skill.source != nil ? "puzzlepiece.extension.fill" : skill.framework.iconSystemName)
                                .font(.system(size: 13))
                                .foregroundStyle(AgentBrand.accentColor(for: skill.framework))
                        }
                    }

                    Text(skill.framework.displayName)
                        .font(FlotillaTypography.caption2.weight(.semibold))
                        .foregroundStyle(AgentBrand.accentColor(for: skill.framework))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(AgentBrand.accentColor(for: skill.framework).opacity(0.12), in: Capsule())

                    if let version = skill.version {
                        Text("v\(version)")
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundStyle(FlotillaColors.textTertiary)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1.5)
                            .background(FlotillaColors.surface, in: Capsule())
                    }

                    Spacer(minLength: 0)

                    scopeBadge(skill.scope, source: skill.source)
                }
                .frame(height: 32)

                Spacer().frame(height: 8)

                // Middle: Title, Invocation/Tags/Folder, and Description
                VStack(alignment: .leading, spacing: 4) {
                    Text(skill.name)
                        .font(FlotillaTypography.headline)
                        .foregroundStyle(FlotillaColors.textPrimary)
                        .lineLimit(1)

                    // Secondary info line: command hint > tags > directory path
                    Group {
                        if let hint = skill.argumentHint {
                            HStack(spacing: 4) {
                                Text("/\(skill.name)")
                                    .fontWeight(.semibold)
                                Text(hint)
                                    .foregroundStyle(FlotillaColors.textTertiary)
                            }
                            .font(.system(size: 9.5, design: .monospaced))
                            .foregroundStyle(FlotillaColors.accent)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1.5)
                            .background(FlotillaColors.canvas.opacity(0.7), in: RoundedRectangle(cornerRadius: 3))
                            .lineLimit(1)
                        } else if !skill.tags.isEmpty {
                            HStack(spacing: 4) {
                                ForEach(skill.tags.prefix(3), id: \.self) { tag in
                                    Text("#\(tag)")
                                        .font(.system(size: 9.5))
                                        .foregroundStyle(FlotillaColors.textTertiary)
                                        .padding(.horizontal, 4.5)
                                        .padding(.vertical, 1)
                                        .background(FlotillaColors.surface, in: RoundedRectangle(cornerRadius: 3))
                                }
                                if skill.tags.count > 3 {
                                    Text("+\(skill.tags.count - 3)")
                                        .font(.system(size: 9, design: .monospaced))
                                        .foregroundStyle(FlotillaColors.textTertiary)
                                }
                            }
                            .lineLimit(1)
                        } else {
                            Text(skill.url.deletingLastPathComponent().lastPathComponent)
                                .font(.system(size: 10, design: .monospaced))
                                .foregroundStyle(FlotillaColors.textTertiary)
                                .lineLimit(1)
                        }
                    }
                    .frame(height: 18, alignment: .leading)

                    Text(skill.description.isEmpty ? "No description provided." : skill.description)
                        .font(FlotillaTypography.caption)
                        .foregroundStyle(skill.description.isEmpty ? FlotillaColors.textTertiary : FlotillaColors.textSecondary)
                        .lineLimit(2)
                        .lineSpacing(2)
                        .frame(maxWidth: .infinity, alignment: .topLeading)
                }

                Spacer(minLength: 0)

                Divider()
                    .opacity(0.4)
                    .padding(.vertical, 6)

                // Bottom Row: Bundle stats & Open hint
                HStack(spacing: 6) {
                    // Resource Badges
                    if skill.bundleStats.scriptsCount > 0 {
                        HStack(spacing: 3) {
                            Image(systemName: "bolt.fill")
                                .font(.system(size: 8.5))
                            Text("\(skill.bundleStats.scriptsCount) script\(skill.bundleStats.scriptsCount == 1 ? "" : "s")")
                        }
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(FlotillaColors.accent)
                    }

                    if skill.bundleStats.referencesCount > 0 {
                        HStack(spacing: 3) {
                            Image(systemName: "doc.text.fill")
                                .font(.system(size: 8.5))
                            Text("\(skill.bundleStats.referencesCount) doc\(skill.bundleStats.referencesCount == 1 ? "" : "s")")
                        }
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(FlotillaColors.statusReady)
                    }

                    if skill.bundleStats.dataCount > 0 {
                        HStack(spacing: 3) {
                            Image(systemName: "tablecells.fill")
                                .font(.system(size: 8.5))
                            Text("\(skill.bundleStats.dataCount) data")
                        }
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(FlotillaColors.statusWorking)
                    }

                    if skill.bundleStats.scriptsCount == 0 && skill.bundleStats.referencesCount == 0 && skill.bundleStats.dataCount == 0 {
                        Text("~\(skill.bundleStats.estimatedReadMinutes)m read • \(skill.bundleStats.lineCount) lines")
                            .font(.system(size: 10))
                            .foregroundStyle(FlotillaColors.textTertiary)
                    }

                    Spacer(minLength: 0)

                    if let date = skill.bundleStats.lastModified {
                        Text(formatRelativeDate(date))
                            .font(.system(size: 10))
                            .foregroundStyle(FlotillaColors.textTertiary)
                    }

                    Image(systemName: "arrow.right")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(isHovered ? FlotillaColors.accent : FlotillaColors.textTertiary)
                }
                .frame(height: 20)
            }
            .padding(FlotillaSpacing.medium)
            .frame(height: 188)
            .background(FlotillaColors.surfaceElevated)
            .clipShape(RoundedRectangle(cornerRadius: FlotillaRadius.card, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: FlotillaRadius.card, style: .continuous)
                    .strokeBorder(
                        isHovered ? AgentBrand.accentColor(for: skill.framework).opacity(0.5) : FlotillaColors.separator.opacity(0.6),
                        lineWidth: 1
                    )
            }
            .shadow(color: Color.black.opacity(isHovered ? 0.22 : 0.05), radius: isHovered ? 8 : 2, y: isHovered ? 4 : 1)
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

// MARK: - Helpers

private func formatRelativeDate(_ date: Date) -> String {
    let now = Date()
    let seconds = max(0, now.timeIntervalSince(date))
    if seconds < 60 {
        return "just now"
    } else if seconds < 3600 {
        let mins = Int(seconds / 60)
        return "\(mins)m ago"
    } else if seconds < 86400 {
        let hours = Int(seconds / 3600)
        return "\(hours)h ago"
    } else if seconds < 86400 * 7 {
        let days = Int(seconds / 86400)
        return "\(days)d ago"
    } else {
        let formatter = DateFormatter()
        formatter.dateFormat = "MMM d"
        return formatter.string(from: date)
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

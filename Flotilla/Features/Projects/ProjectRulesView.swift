import SwiftUI
import AppKit
import SessionKit
import DesignSystem

/// Rules tab for a project workspace.
///
/// Features a responsive card grid showing all discovered global and project instruction rules
/// (AGENTS.md, CLAUDE.md, GEMINI.md, .cursorrules, copilot-instructions.md, etc.).
/// Clicking a card opens an enlarged rule view with rendered Markdown documentation
/// and an interactive in-place editor with ⌘S save bridge.
struct ProjectRulesView: View {
    let project: Project
    @Bindable var store: AppStore

    @State private var viewModel: ProjectRulesViewModel
    @State private var searchText = ""
    @State private var enlargedRule: RuleFileEntry?
    @State private var isEditing = false
    @FocusState private var isEditorFocused: Bool

    @State private var showCreatedNotification = false
    @State private var createdFileName = ""

    init(
        project: Project,
        store: AppStore,
        service: any WorkspaceFileServicing = WorkspaceFileService()
    ) {
        self.project = project
        self.store = store
        self._viewModel = State(initialValue: ProjectRulesViewModel(projectRoot: project.rootPath, service: service))
    }

    var body: some View {
        ZStack {
            VStack(spacing: 0) {
                headerBar
                Divider()

                ScrollView {
                    if viewModel.isLoading && viewModel.entries.isEmpty {
                        ProgressView("Scanning rules…")
                            .frame(maxWidth: .infinity, minHeight: 300)
                    } else if filteredEntries.isEmpty {
                        emptyStateView
                            .frame(maxWidth: .infinity, minHeight: 320)
                    } else {
                        rulesGrid
                            .padding(FlotillaSpacing.large)
                    }
                }
                .background(FlotillaColors.canvas)
            }

            // Enlarged Rule Card Modal
            if let rule = enlargedRule {
                enlargedCardOverlay(for: rule)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .task(id: project.id) {
            await viewModel.load()
        }
        .overlay(alignment: .bottomTrailing) {
            if showCreatedNotification {
                HStack(spacing: FlotillaSpacing.small) {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(FlotillaColors.statusWorking)
                    Text("Created \(createdFileName)")
                        .font(FlotillaTypography.caption.weight(.medium))
                }
                .padding(.horizontal, FlotillaSpacing.medium)
                .padding(.vertical, FlotillaSpacing.small)
                .background(FlotillaColors.surfaceElevated, in: RoundedRectangle(cornerRadius: FlotillaRadius.card))
                .overlay {
                    RoundedRectangle(cornerRadius: FlotillaRadius.card)
                        .strokeBorder(FlotillaColors.statusWorking.opacity(0.4))
                }
                .padding(FlotillaSpacing.large)
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
    }

    // MARK: - Header Bar

    private var headerBar: some View {
        HStack(spacing: FlotillaSpacing.medium) {
            HStack(spacing: FlotillaSpacing.small) {
                Text("Rules")
                    .font(FlotillaTypography.headline)
                    .foregroundStyle(FlotillaColors.textPrimary)

                Text("\(filteredEntries.count)")
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
                TextField("Search rules…", text: $searchText)
                    .textFieldStyle(.plain)
                    .font(.system(size: 11.5, design: .monospaced))
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
                Text("All").tag(RulesFilter.all)
                Text("Global").tag(RulesFilter.global)
                Text("Project").tag(RulesFilter.project)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 200)

            // Add Template Menu
            Menu {
                Button("Create AGENTS.md Guide") {
                    createTemplateFile(named: "AGENTS.md", content: defaultAgentsGuide)
                }
                Button("Create CLAUDE.md Rules") {
                    createTemplateFile(named: "CLAUDE.md", content: defaultClaudeRules)
                }
                Button("Create GEMINI.md Rules") {
                    createTemplateFile(named: "GEMINI.md", content: defaultGeminiRules)
                }
                Button("Create .cursorrules") {
                    createTemplateFile(named: ".cursorrules", content: defaultCursorRules)
                }
                Button("Create copilot-instructions.md") {
                    createTemplateFile(named: "copilot-instructions.md", content: defaultCopilotRules)
                }
            } label: {
                Label("Add Template", systemImage: "plus.bubble")
                    .font(FlotillaTypography.caption)
            }
            .buttonStyle(.bordered)
            .controlSize(.small)

            Button {
                Task { await viewModel.load() }
            } label: {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: FlotillaIconSize.small))
            }
            .buttonStyle(.plain)
            .help("Refresh rules")
        }
        .padding(.horizontal, FlotillaSpacing.large)
        .padding(.vertical, FlotillaSpacing.small + 2)
        .background(FlotillaColors.surface)
    }

    // MARK: - Rules Grid

    private var filteredEntries: [RuleFileEntry] {
        let base: [RuleFileEntry] = switch viewModel.filter {
        case .all: viewModel.entries
        case .global: viewModel.entries.filter { $0.scope == .global }
        case .project: viewModel.entries.filter { $0.scope == .project }
        }

        guard !searchText.isEmpty else { return base }
        return base.filter {
            $0.relativePath.localizedCaseInsensitiveContains(searchText) ||
            $0.name.localizedCaseInsensitiveContains(searchText)
        }
    }

    private var rulesGrid: some View {
        LazyVGrid(
            columns: [GridItem(.adaptive(minimum: 280, maximum: 380), spacing: FlotillaSpacing.medium)],
            spacing: FlotillaSpacing.medium
        ) {
            ForEach(filteredEntries) { entry in
                RuleCardView(entry: entry) {
                    openRule(entry)
                }
            }
        }
    }

    private func openRule(_ entry: RuleFileEntry) {
        isEditing = false
        Task {
            await viewModel.select(entry)
            withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) {
                enlargedRule = entry
            }
        }
    }

    private func closeRule() {
        withAnimation(.easeOut(duration: 0.2)) {
            enlargedRule = nil
            isEditing = false
        }
    }

    // MARK: - Enlarged Card Overlay

    private func enlargedCardOverlay(for entry: RuleFileEntry) -> some View {
        ZStack {
            // Backdrop
            Color.black.opacity(0.55)
                .ignoresSafeArea()
                .onTapGesture {
                    closeRule()
                }

            // Floating Card
            VStack(spacing: 0) {
                enlargedCardHeader(entry)
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

    private func enlargedCardHeader(_ entry: RuleFileEntry) -> some View {
        VStack(alignment: .leading, spacing: FlotillaSpacing.small) {
            HStack(alignment: .top, spacing: FlotillaSpacing.medium) {
                // Large Authentic Material Icon
                ZStack {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(FlotillaColors.accent.opacity(0.14))
                        .frame(width: 44, height: 44)
                    MaterialFileIcon(url: entry.url, size: 26)
                }

                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 8) {
                        Text(entry.name)
                            .font(.title3.weight(.bold).monospaced())
                            .foregroundStyle(FlotillaColors.textPrimary)

                        scopeBadge(entry.scope)
                    }

                    Text(ruleSubtitle(for: entry))
                        .font(FlotillaTypography.callout)
                        .foregroundStyle(FlotillaColors.textSecondary)
                }

                Spacer()

                // Actions
                HStack(spacing: FlotillaSpacing.small) {
                    Button {
                        NSWorkspace.shared.open(entry.url)
                    } label: {
                        Label("Open in App", systemImage: "arrow.up.forward.app")
                            .font(FlotillaTypography.caption)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .help("Open in default system application")

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
                        closeRule()
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
    private func scopeBadge(_ scope: RuleScope) -> some View {
        HStack(spacing: 4) {
            Image(systemName: scope == .global ? "globe" : "folder")
                .font(.system(size: 9))
            Text(scope == .global ? "global" : "project")
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
            "No Rules Found",
            systemImage: "doc.badge.gearshape",
            description: Text(emptyDescription)
        )
    }

    private var emptyDescription: String {
        switch viewModel.filter {
        case .all: return "No rule instruction files found. Add AGENTS.md, CLAUDE.md, GEMINI.md, or .cursorrules to get started."
        case .global: return "No global rules found in ~/.claude/ or ~/.agents/."
        case .project: return "No project-scoped rules found in this workspace root."
        }
    }

    private func ruleSubtitle(for entry: RuleFileEntry) -> String {
        let name = entry.name.lowercased()
        if name.contains("claude") {
            return "Claude Code instructions & workflow policies"
        } else if name.contains("gemini") {
            return "Gemini CLI system context & project guidance"
        } else if name.contains("agent") {
            return "Autonomous coding agent guide & architecture reference"
        } else if name.contains("cursor") {
            return "Cursor IDE workspace rules & code conventions"
        } else if name.contains("copilot") {
            return "GitHub Copilot prompt instructions"
        } else {
            return "AI assistant instruction file"
        }
    }

    // MARK: - Template Creation

    private func createTemplateFile(named fileName: String, content: String) {
        let targetURL = project.rootPath.appendingPathComponent(fileName)
        guard !FileManager.default.fileExists(atPath: targetURL.path) else {
            Task {
                await viewModel.load()
                if let entry = viewModel.entries.first(where: { $0.url == targetURL }) {
                    openRule(entry)
                }
            }
            return
        }

        do {
            try content.write(to: targetURL, atomically: true, encoding: .utf8)
            createdFileName = fileName
            withAnimation(FlotillaMotion.snappy.curve) {
                showCreatedNotification = true
            }
            Task {
                await viewModel.load()
                if let entry = viewModel.entries.first(where: { $0.url == targetURL }) {
                    openRule(entry)
                }
            }
        } catch {
            return
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) {
            withAnimation(FlotillaMotion.snappy.curve) {
                showCreatedNotification = false
            }
        }
    }

    // MARK: - Default Templates

    private var defaultAgentsGuide: String {
        """
        # \(project.name) — Agent Guide

        > Guidelines and architecture reference for AI coding assistants working on \(project.name).

        ## Project Overview
        - **Language / Stack:** 
        - **Build System:** 
        - **Primary Entrypoint:** 

        ## Development Commands
        - **Build:** 
        - **Test:** 
        - **Lint:** 

        ## Architecture & Conventions
        - 
        """
    }

    private var defaultClaudeRules: String {
        """
        # Claude Code Rules for \(project.name)

        ## Guidelines
        - Always run unit tests before and after making code changes.
        - Maintain strict concurrency and type safety.
        - Keep functions focused and modular.
        """
    }

    private var defaultGeminiRules: String {
        """
        # Gemini CLI Instructions for \(project.name)

        ## Project Context
        - Architectural conventions and coding guidelines for \(project.name).
        - Test before committing changes.
        """
    }

    private var defaultCursorRules: String {
        """
        # Rules for \(project.name)

        - Follow clean architecture patterns.
        - Ensure all public APIs are properly documented.
        - Never modify generated files directly.
        """
    }

    private var defaultCopilotRules: String {
        """
        # GitHub Copilot Instructions for \(project.name)

        - Use modern idioms and strictly type-safe constructs.
        - Maintain unit tests alongside all logic changes.
        """
    }
}

// MARK: - Rule Card View

struct RuleCardView: View {
    let entry: RuleFileEntry
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
                        MaterialFileIcon(url: entry.url, size: 20)
                    }

                    Spacer()

                    scopeBadge(entry.scope)
                }

                // Middle: Name & Description
                VStack(alignment: .leading, spacing: 4) {
                    Text(entry.relativePath)
                        .font(.system(size: 13, weight: .semibold, design: .monospaced))
                        .foregroundStyle(FlotillaColors.textPrimary)
                        .lineLimit(1)

                    Text(cardDescription)
                        .font(FlotillaTypography.caption)
                        .foregroundStyle(FlotillaColors.textSecondary)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(minHeight: 48, alignment: .topLeading)

                Divider()
                    .opacity(0.5)

                // Bottom Row: Location & Open Hint
                HStack {
                    Text(entry.url.deletingLastPathComponent().lastPathComponent)
                        .font(.system(size: 10.5, design: .monospaced))
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

    private var cardDescription: String {
        let name = entry.name.lowercased()
        if name.contains("claude") {
            return "Claude Code instructions & project policies."
        } else if name.contains("gemini") {
            return "Gemini CLI instructions & context."
        } else if name.contains("agent") {
            return "Autonomous agent guidelines & architecture."
        } else if name.contains("cursor") {
            return "Cursor IDE workspace rules & prompt behavior."
        } else if name.contains("copilot") {
            return "GitHub Copilot prompt instructions."
        } else {
            return "AI coding assistant instructions."
        }
    }

    @ViewBuilder
    private func scopeBadge(_ scope: RuleScope) -> some View {
        HStack(spacing: 3) {
            Image(systemName: scope == .global ? "globe" : "folder")
                .font(.system(size: 8))
            Text(scope == .global ? "global" : "project")
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

enum RulesFilter: String, Sendable {
    case all, global, project
}

@Observable
@MainActor
final class ProjectRulesViewModel {
    private let projectRoot: URL
    private let service: any WorkspaceFileServicing

    private(set) var entries: [RuleFileEntry] = []
    var selectedEntry: RuleFileEntry?
    var content = ""
    var savedAt: Date?
    var filter: RulesFilter = .all
    private(set) var isLoading = false
    private(set) var isSaving = false
    private(set) var message: String?

    init(projectRoot: URL, service: any WorkspaceFileServicing = WorkspaceFileService()) {
        self.projectRoot = projectRoot
        self.service = service
    }

    func load() async {
        fileScanLog.notice("ProjectRulesViewModel.load: root=\(self.projectRoot.path, privacy: .public)")
        isLoading = true
        defer { isLoading = false }
        do {
            let projectEntries = try await service.instructionFiles(in: projectRoot)
            let globalEntries = try await service.globalInstructionFiles()
            entries = globalEntries + projectEntries
            message = nil
        } catch {
            entries = []
            message = error.localizedDescription
        }
    }

    func select(_ entry: RuleFileEntry) async {
        do {
            content = try await service.readText(at: entry.url)
            let fileManager = FileManager.default
            if let attributes = try? fileManager.attributesOfItem(atPath: entry.url.path),
               let modificationDate = attributes[.modificationDate] as? Date {
                savedAt = modificationDate
            }
            selectedEntry = entry
            message = nil
        } catch {
            message = "Could not open \(entry.relativePath): \(error.localizedDescription)"
        }
    }

    func save() async {
        guard let selectedEntry else { return }

        let fileManager = FileManager.default
        let currentAttributes = try? fileManager.attributesOfItem(atPath: selectedEntry.url.path)
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
            try await service.writeText(content, to: selectedEntry.url)
            savedAt = Date()
            message = "Saved"
        } catch {
            message = "Could not save: \(error.localizedDescription)"
        }
    }
}

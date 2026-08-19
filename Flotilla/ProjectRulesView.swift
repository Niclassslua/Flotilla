import SwiftUI
import AppKit
import SessionKit
import DesignSystem

/// Rules tab for a project workspace.
///
/// Three-section layout: All / Global / Project filter, with an HSplitView
/// showing the file list on the left and the editor on the right.
/// Subsumes ProjectRulesSheet's functionality — including its template menu.
struct ProjectRulesView: View {
    let project: Project
    @Bindable var store: AppStore

    @State private var viewModel: ProjectRulesViewModel
    @FocusState private var isEditorFocused: Bool

    @State private var showCreatedNotification = false
    @State private var createdFileName = ""

    init(project: Project, store: AppStore, service: any WorkspaceFileServicing = WorkspaceFileService()) {
        self.project = project
        self.store = store
        self._viewModel = State(initialValue: ProjectRulesViewModel(projectRoot: project.rootPath, service: service))
    }

    var body: some View {
        HSplitView {
            fileList
                .frame(minWidth: 220, idealWidth: 280, maxWidth: 360)
            editor
                .frame(minWidth: 320)
        }
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

    @State private var viewMode: RuleViewMode = .preview

    enum RuleViewMode: String, CaseIterable, Identifiable {
        case preview = "Preview"
        case edit = "Edit"
        var id: Self { self }
    }

    // MARK: - File List

    private var filteredEntries: [RuleFileEntry] {
        switch viewModel.filter {
        case .all: viewModel.entries
        case .global: viewModel.entries.filter { $0.scope == .global }
        case .project: viewModel.entries.filter { $0.scope == .project }
        }
    }

    private var fileList: some View {
        VStack(spacing: 0) {
            // Header with filter + template menu
            VStack(spacing: FlotillaSpacing.small) {
                HStack(spacing: FlotillaSpacing.small) {
                    Text("Rules")
                        .font(.headline)
                    Spacer()
                    Menu {
                        Button("Create AGENTS.md Guide") {
                            createTemplateFile(named: "AGENTS.md", content: defaultAgentsGuide)
                        }
                        Button("Create CLAUDE.md Rules") {
                            createTemplateFile(named: "CLAUDE.md", content: defaultClaudeRules)
                        }
                        Button("Create .cursorrules") {
                            createTemplateFile(named: ".cursorrules", content: defaultCursorRules)
                        }
                    } label: {
                        Label("Add Rule Template", systemImage: "plus.bubble")
                            .font(FlotillaTypography.caption)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)

                    Button {
                        Task { await viewModel.load() }
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .buttonStyle(.plain)
                    .help("Refresh rules")
                }

                Picker("Scope", selection: $viewModel.filter) {
                    Text("All").tag(RulesFilter.all)
                    Text("Global").tag(RulesFilter.global)
                    Text("Project").tag(RulesFilter.project)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
            }
            .padding(.horizontal, FlotillaSpacing.medium)
            .padding(.vertical, FlotillaSpacing.small)
            .background(FlotillaColors.surface)

            Divider()

            if viewModel.isLoading && viewModel.entries.isEmpty {
                ProgressView("Loading rules…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(FlotillaColors.surface)
            } else if filteredEntries.isEmpty {
                ContentUnavailableView(
                    "No Rules",
                    systemImage: "doc.badge.gearshape",
                    description: Text(emptyDescription)
                )
                .background(FlotillaColors.surface)
            } else {
                List(filteredEntries, selection: $viewModel.selectedEntry) { entry in
                    Button {
                        Task { await viewModel.select(entry) }
                    } label: {
                        HStack(spacing: FlotillaSpacing.small) {
                            MaterialFileIcon(url: entry.url, size: 16)
                            Text(entry.relativePath)
                                .font(FlotillaTypography.body)
                                .lineLimit(1)
                            Spacer()
                            scopeBadge(entry.scope)
                        }
                    }
                    .buttonStyle(.plain)
                    .listRowBackground(
                        RoundedRectangle(cornerRadius: FlotillaRadius.control, style: .continuous)
                            .fill(viewModel.selectedEntry == entry ? FlotillaColors.accent.opacity(0.09) : .clear)
                    )
                }
                .scrollContentBackground(.hidden)
                .background(FlotillaColors.surface)
            }
        }
        .background(FlotillaColors.surface)
    }

    @ViewBuilder
    private func scopeBadge(_ scope: RuleScope) -> some View {
        let (text, icon) = switch scope {
        case .global: ("global", "globe")
        case .project: ("project", "folder")
        }
        HStack(spacing: 3) {
            Image(systemName: icon)
                .font(.system(size: 9))
            Text(text)
                .font(FlotillaTypography.caption2)
        }
        .foregroundStyle(FlotillaColors.textTertiary)
        .padding(.horizontal, 5)
        .padding(.vertical, 1)
        .background(FlotillaColors.surfaceElevated, in: Capsule())
    }

    private var emptyDescription: String {
        switch viewModel.filter {
        case .all: "Add CLAUDE.md, AGENTS.md, or GEMINI.md to this project, or create global rules in ~/.claude/ or ~/.agents/."
        case .global: "No global rule files found. Create CLAUDE.md in ~/.claude/ or AGENTS.md in ~/.agents/."
        case .project: "Add CLAUDE.md, AGENTS.md, or GEMINI.md to this project."
        }
    }

    // MARK: - Editor

    @ViewBuilder
    private var editor: some View {
        if let selectedEntry = viewModel.selectedEntry {
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: FlotillaSpacing.small) {
                    MaterialFileIcon(url: selectedEntry.url, size: 18)

                    VStack(alignment: .leading, spacing: 1) {
                        Text(selectedEntry.url.lastPathComponent)
                            .font(FlotillaTypography.headline)
                        Text(selectedEntry.relativePath)
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundStyle(FlotillaColors.textTertiary)
                    }

                    Spacer()

                    scopeBadge(selectedEntry.scope)

                    Picker("Mode", selection: $viewMode) {
                        ForEach(RuleViewMode.allCases) { mode in
                            Text(mode.rawValue).tag(mode)
                        }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .frame(width: 130)

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
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .keyboardShortcut("s", modifiers: .command)
                    .disabled(viewModel.isSaving)
                }
                .padding(.horizontal, FlotillaSpacing.medium)
                .padding(.vertical, FlotillaSpacing.small)
                .background(FlotillaColors.surface)

                Divider()

                if viewMode == .preview {
                    ScrollView {
                        MarkdownView(markdown: viewModel.content)
                            .padding(FlotillaSpacing.large)
                    }
                    .background(FlotillaColors.canvas)
                } else {
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
                }
            }
        } else {
            ContentUnavailableView(
                "Select a Rule File",
                systemImage: "doc.text.magnifyingglass",
                description: Text("Review and edit the rules this project gives its agents.")
            )
            .background(FlotillaColors.terminalCanvas)
        }
    }

    // MARK: - Template File Creation

    private func createTemplateFile(named fileName: String, content: String) {
        let fileURL = project.rootPath.appendingPathComponent(fileName)
        guard !FileManager.default.fileExists(atPath: fileURL.path) else {
            createdFileName = "\(fileName) (already exists)"
            showNotification()
            return
        }
        do {
            try content.write(to: fileURL, atomically: true, encoding: .utf8)
            createdFileName = fileName
            showNotification()
            Task { await viewModel.load() }
        } catch {
            store.lastOperationError = "Failed to create \(fileName): \(error.localizedDescription)"
        }
    }

    private func showNotification() {
        withAnimation(FlotillaMotion.snappy.curve) {
            showCreatedNotification = true
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

    private var defaultCursorRules: String {
        """
        # Rules for \(project.name)

        - Follow clean architecture patterns.
        - Ensure all public APIs are properly documented.
        - Never modify generated files directly.
        """
    }
}

// MARK: - Filter

enum RulesFilter: String, Sendable {
    case all, global, project
}

// MARK: - ViewModel

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

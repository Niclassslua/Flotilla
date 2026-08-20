import SwiftUI
import DesignSystem

enum InstructionFileFilter: Equatable {
    case all
    case rules
    case skills

    func includes(_ entry: RuleFileEntry) -> Bool {
        let isSkill = entry.url.lastPathComponent == "SKILL.md"
            || entry.relativePath.contains("/skills/")
        return switch self {
        case .all: true
        case .rules: !isSkill
        case .skills: isSkill
        }
    }

    var title: String {
        switch self {
        case .all: "Rules & Skills"
        case .rules: "Rules"
        case .skills: "Skills"
        }
    }
}

struct RulesPanelView: View {
    let rootURL: URL
    let filter: InstructionFileFilter
    @Bindable var viewModel: RulesPanelViewModel
    @FocusState private var isEditorFocused: Bool
    @State private var showLoadError = false

    init(
        rootURL: URL,
        filter: InstructionFileFilter = .all,
        service: any WorkspaceFileServicing = WorkspaceFileService()
    ) {
        self.rootURL = rootURL
        self.filter = filter
        self._viewModel = Bindable(wrappedValue: RulesPanelViewModel(root: rootURL, service: service))
    }

    init(viewModel: RulesPanelViewModel) {
        self.rootURL = viewModel.rootURL
        self.filter = .all
        self._viewModel = Bindable(wrappedValue: viewModel)
    }

    private var entries: [RuleFileEntry] {
        viewModel.entries.filter(filter.includes)
    }

    var body: some View {
        HSplitView {
            fileList
                .frame(minWidth: 180, idealWidth: 240, maxWidth: 320)
            editor
                .frame(minWidth: 320)
        }
        .task(id: rootURL) { 
            await viewModel.load()
            showLoadError = viewModel.message != nil && viewModel.message?.hasPrefix("Could not") == true
        }
        .alert("Load Error", isPresented: $showLoadError) {
            Button("OK") { showLoadError = false }
        } message: {
            Text(viewModel.message ?? "Unknown error")
        }
    }

    private var fileList: some View {
        VStack(spacing: 0) {
            HStack {
                Text(filter.title)
                    .font(.headline)
                Spacer()
                Button {
                    Task { await viewModel.load() }
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.plain)
                .help("Refresh instruction files")
            }
            .padding(.horizontal, FlotillaSpacing.medium)
            .padding(.vertical, FlotillaSpacing.small)
            .background(FlotillaColors.surface)

            Divider()

            if viewModel.isLoading && entries.isEmpty {
                ProgressView("Loading instructions…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(FlotillaColors.surface)
            } else if entries.isEmpty, !viewModel.isLoading {
                ContentUnavailableView(
                    filter == .skills ? "No Skills" : "No Instructions",
                    systemImage: filter == .skills ? "hammer" : "doc.badge.gearshape",
                    description: Text(emptyDescription)
                )
                .accessibilityIdentifier("RulesPanel.Empty")
                .background(FlotillaColors.surface)
            } else {
                List(entries, selection: $viewModel.selectedEntry) { entry in
                    Button {
                        Task { await viewModel.select(entry) }
                    } label: {
                        HStack(spacing: 8) {
                            MaterialFileIcon(url: entry.url, size: 17)
                            Text(entry.relativePath)
                                .font(.system(size: 12, design: .monospaced))
                                .lineLimit(1)
                        }
                    }
                    .buttonStyle(.plain)
                    .listRowBackground(
                        RoundedRectangle(cornerRadius: FlotillaRadius.control, style: .continuous)
                            .fill(viewModel.selectedEntry == entry ? FlotillaColors.accent.opacity(0.09) : .clear)
                    )
                    .accessibilityIdentifier("RulesPanel.File-\(entry.relativePath)")
                }
                .scrollContentBackground(.hidden)
                .background(FlotillaColors.surface)
                .accessibilityIdentifier("RulesPanel.FileList")
            }
        }
        .background(FlotillaColors.surface)
    }

    private var emptyDescription: String {
        switch filter {
        case .all: "Add CLAUDE.md, AGENTS.md, GEMINI.md, or a skill file."
        case .rules: "Add CLAUDE.md, AGENTS.md, or GEMINI.md to this project."
        case .skills: "Add SKILL.md under .claude/skills, .agents/skills, or .codex/skills."
        }
    }

@ViewBuilder
    private var editor: some View {
        @Bindable var bindableViewModel = viewModel
        if let selectedEntry = viewModel.selectedEntry {
            VStack(alignment: .leading, spacing: 0) {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(selectedEntry.url.lastPathComponent)
                            .font(.headline)
                        Text(selectedEntry.relativePath)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    if let message = viewModel.message {
                        Label(
                            message,
                            systemImage: message.hasPrefix("Saved") ? "checkmark.circle.fill" : "exclamationmark.triangle.fill"
                        )
                        .font(.caption)
                        .foregroundStyle(message.hasPrefix("Saved") ? FlotillaColors.success : Color.red)
                        .accessibilityElement(children: .ignore)
                        .accessibilityLabel(message)
                        .accessibilityIdentifier("RulesPanel.SaveConfirmation")
                    }
                    Button("Save") {
                        // AppKit commits the final TextEditor edit when focus
                        // leaves the underlying NSTextView. Yield once before
                        // reading the observable model so the last keystroke is
                        // never omitted from the file written to disk.
                        isEditorFocused = false
                        Task {
                            await Task.yield()
                            await viewModel.save()
                        }
                    }
                        .keyboardShortcut("s", modifiers: .command)
                        .disabled(viewModel.isSaving)
                        .accessibilityIdentifier("RulesPanel.SaveButton")
                }
                .padding(.horizontal, FlotillaSpacing.medium)
                .padding(.vertical, FlotillaSpacing.small)
                .background(FlotillaColors.surface)
                Divider()
                TextEditor(text: $bindableViewModel.content)
                    .font(.system(.body, design: .monospaced))
                    .scrollContentBackground(.hidden)
                    .padding(FlotillaSpacing.small)
                    .background(FlotillaColors.terminalCanvas)
                    .focused($isEditorFocused)
                    .accessibilityIdentifier("RulesPanel.Editor")
            }
        } else {
            ContentUnavailableView(
                "Select an Instruction File",
                systemImage: "doc.text.magnifyingglass",
                description: Text("Review and edit the rules this project gives its agents.")
            )
            .accessibilityIdentifier("RulesPanel.NoSelection")
            .background(FlotillaColors.terminalCanvas)
        }
    }
}

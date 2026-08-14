import SwiftUI

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
    @State private var viewModel: RulesPanelViewModel
    @FocusState private var isEditorFocused: Bool

    init(
        rootURL: URL,
        filter: InstructionFileFilter = .all,
        service: any WorkspaceFileServicing = WorkspaceFileService()
    ) {
        self.rootURL = rootURL
        self.filter = filter
        _viewModel = State(initialValue: RulesPanelViewModel(root: rootURL, service: service))
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
        .task(id: rootURL) { await viewModel.load() }
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
            .padding(12)

            Divider()

            if entries.isEmpty, !viewModel.isLoading {
                ContentUnavailableView(
                    filter == .skills ? "No Skills" : "No Instructions",
                    systemImage: filter == .skills ? "hammer" : "doc.badge.gearshape",
                    description: Text(emptyDescription)
                )
                .accessibilityIdentifier("RulesPanel.Empty")
            } else {
                List(entries, selection: $viewModel.selectedEntry) { entry in
                    Button {
                        Task { await viewModel.select(entry) }
                    } label: {
                        Label(entry.relativePath, systemImage: entry.url.lastPathComponent == "SKILL.md" ? "hammer" : "doc.text")
                            .lineLimit(2)
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("RulesPanel.File-\(entry.relativePath)")
                }
                .accessibilityIdentifier("RulesPanel.FileList")
            }
        }
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
                            systemImage: message == "Saved" ? "checkmark.circle.fill" : "exclamationmark.triangle.fill"
                        )
                            .font(.caption)
                            .foregroundStyle(message == "Saved" ? Color.green : Color.red)
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
                .padding(12)
                Divider()
                TextEditor(text: $bindableViewModel.content)
                    .font(.system(.body, design: .monospaced))
                    .padding(6)
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
        }
    }
}

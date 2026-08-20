import SwiftUI
import DesignSystem
import MarkdownParser

struct FileBrowserView: View {
    let rootURL: URL
    @Bindable var viewModel: FileBrowserViewModel
    @FocusState private var isEditorFocused: Bool

    @State private var isShowingNewFileDialog = false
    @State private var newFileName = ""

    init(rootURL: URL, service: any WorkspaceFileServicing = WorkspaceFileService()) {
        self.rootURL = rootURL
        self._viewModel = Bindable(wrappedValue: FileBrowserViewModel(root: rootURL, service: service))
    }

    init(viewModel: FileBrowserViewModel) {
        self.rootURL = viewModel.rootURL
        self._viewModel = Bindable(wrappedValue: viewModel)
    }

    var body: some View {
        HSplitView {
            fileNavigator
                .frame(minWidth: 210, idealWidth: 260, maxWidth: 360)
                .frame(maxHeight: .infinity)
                .layoutPriority(1)
            editor
                .frame(minWidth: 360, maxWidth: .infinity)
                .frame(maxHeight: .infinity)
        }
        .frame(maxHeight: .infinity)
        .task(id: rootURL) { await viewModel.refresh() }
        .alert("New File", isPresented: $isShowingNewFileDialog) {
            TextField("File name (e.g. README.md, .env, main.ts)", text: $newFileName)
            Button("Create") {
                createNewFile()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Enter a name for the new file to create in this workspace.")
        }
    }

    private func createNewFile() {
        let trimmed = newFileName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        let targetURL = rootURL.appendingPathComponent(trimmed)
        do {
            let parentDir = targetURL.deletingLastPathComponent()
            try FileManager.default.createDirectory(at: parentDir, withIntermediateDirectories: true)
            if !FileManager.default.fileExists(atPath: targetURL.path) {
                try "".write(to: targetURL, atomically: true, encoding: .utf8)
            }
            Task {
                await viewModel.refresh()
                let newNode = FileNode(url: targetURL, isDirectory: false)
                await viewModel.select(newNode)
            }
        } catch {}
    }

    private var fileNavigator: some View {
        VStack(spacing: 0) {
            HStack(spacing: FlotillaSpacing.small) {
                Label(rootURL.lastPathComponent, systemImage: "folder")
                    .font(.headline)
                    .lineLimit(1)
                Spacer()

                Button {
                    newFileName = ""
                    isShowingNewFileDialog = true
                } label: {
                    Label("New File", systemImage: "plus")
                }
                .labelStyle(.iconOnly)
                .help("New File (⌘N)")
                .keyboardShortcut("n", modifiers: .command)
                .accessibilityIdentifier("FileBrowser.NewFileButton")

                Button {
                    Task { await viewModel.refresh() }
                } label: {
                    Label("Refresh Files", systemImage: "arrow.clockwise")
                }
                .labelStyle(.iconOnly)
                .help("Refresh files")
                .accessibilityIdentifier("FileBrowser.RefreshButton")
            }
            .padding(.horizontal, FlotillaSpacing.medium)
            .padding(.vertical, FlotillaSpacing.small)
            .background(FlotillaColors.surface)

            Divider()

            if viewModel.isLoading && viewModel.nodes.isEmpty {
                ProgressView("Loading files…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(FlotillaColors.surface)
            } else if let errorMessage = viewModel.errorMessage, viewModel.nodes.isEmpty {
                ContentUnavailableView(
                    "Error Loading Files",
                    systemImage: "exclamationmark.triangle",
                    description: Text(errorMessage)
                )
                .accessibilityIdentifier("FileBrowser.Error")
                .background(FlotillaColors.surface)
            } else if viewModel.nodes.isEmpty {
                ContentUnavailableView(
                    "No Files",
                    systemImage: "folder",
                    description: Text("This worktree is empty.")
                )
                .accessibilityIdentifier("FileBrowser.Empty")
                .background(FlotillaColors.surface)
            } else {
                List {
                    OutlineGroup(viewModel.nodes, children: \.children) { node in
                        Button {
                            Task { await viewModel.select(node) }
                        } label: {
                            HStack(spacing: 7) {
                                MaterialFileIcon(node: node, size: 17)
                                Text(node.name)
                                    .font(.system(size: 12, weight: .medium, design: .monospaced))
                                    .foregroundStyle(node.name.hasPrefix(".") ? FlotillaColors.textSecondary : .primary)
                                    .lineLimit(1)
                                    .truncationMode(.tail)
                            }
                            .padding(.vertical, 0.5)
                            .contentShape(.rect)
                        }
                        .buttonStyle(.plain)
                        .disabled(node.isDirectory)
                        .listRowBackground(
                            RoundedRectangle(cornerRadius: FlotillaRadius.control, style: .continuous)
                                .fill(viewModel.selectedNode == node ? FlotillaColors.accent.opacity(0.09) : .clear)
                        )
                        .accessibilityIdentifier("FileBrowser.Row-\(node.name)")
                    }
                }
                .listStyle(.sidebar)
                .scrollContentBackground(.hidden)
                .background(FlotillaColors.surface)
                .accessibilityIdentifier("FileBrowser.List")
            }
        }
        .background(FlotillaColors.surface)
        .frame(maxHeight: .infinity)
    }

    @ViewBuilder
    private var editor: some View {
        if let node = viewModel.selectedNode {
            if viewModel.isBinaryOrUnopenable {
                BinaryFileEditor(node: node)
            } else {
                let isMarkdown = node.url.pathExtension.lowercased() == "md"
                    || node.url.pathExtension.lowercased() == "markdown"
                    || node.url.pathExtension.lowercased() == "mdx"

                if isMarkdown {
                    MarkdownFileEditor(node: node)
                } else {
                    SyntaxHighlightedFileEditor(node: node)
                }
            }
        } else {
            ContentUnavailableView(
                "Select a File",
                systemImage: "doc.text.magnifyingglass",
                description: Text("Open a text file to inspect or edit it in place.")
            )
            .accessibilityIdentifier("FileBrowser.NoSelection")
            .background(FlotillaColors.terminalCanvas)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

extension FileBrowserView {
    @ViewBuilder
    private func MarkdownFileEditor(node: FileNode) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                MaterialFileIcon(node: node, size: 19)
                VStack(alignment: .leading, spacing: 1) {
                    Text(node.name)
                        .font(.system(size: 13, weight: .semibold, design: .monospaced))
                    Text(node.url.path)
                        .font(.system(size: 10.5, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if let message = viewModel.message {
                    Text(message)
                        .font(.caption)
                        .foregroundStyle(.secondary)
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
                .accessibilityIdentifier("FileBrowser.SaveButton")
            }
            .padding(.horizontal, FlotillaSpacing.medium)
            .padding(.vertical, FlotillaSpacing.small)
            .background(FlotillaColors.surface)

            if let errorMessage = viewModel.errorMessage {
                Text(errorMessage)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, FlotillaSpacing.medium)
                    .padding(.vertical, FlotillaSpacing.xSmall)
                    .background(Color.red.opacity(0.08))
                    .accessibilityIdentifier("FileBrowser.ErrorMessage")
            }

            Divider()

            ScrollView {
                MarkdownView(markdown: viewModel.content)
                    .padding(FlotillaSpacing.medium)
            }
            .accessibilityIdentifier("FileBrowser.MarkdownEditor")
            .accessibilityLabel("Markdown editor for \(node.name)")
        }
        .frame(maxHeight: .infinity)
    }

    @ViewBuilder
    private func SyntaxHighlightedFileEditor(node: FileNode) -> some View {
        SyntaxHighlightedTextEditor(
            text: $viewModel.content,
            language: SyntaxHighlightedTextEditor.Language.from(url: node.url),
            font: .system(.body, design: .monospaced),
            onTextChange: { newValue in
                viewModel.content = newValue
            }
        )
        .focused($isEditorFocused)
        .padding(FlotillaSpacing.small)
        .accessibilityIdentifier("FileBrowser.Editor")
    }

    @ViewBuilder
    private func BinaryFileEditor(node: FileNode) -> some View {
        VStack(spacing: FlotillaSpacing.large) {
            HStack(spacing: 8) {
                MaterialFileIcon(node: node, size: 19)
                VStack(alignment: .leading, spacing: 1) {
                    Text(node.name)
                        .font(.system(size: 13, weight: .semibold, design: .monospaced))
                    Text(node.url.path)
                        .font(.system(size: 10.5, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button {
                    NSWorkspace.shared.open(node.url)
                } label: {
                    Label("Open in App", systemImage: "arrow.up.forward.app")
                        .font(FlotillaTypography.caption)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
            .padding(.horizontal, FlotillaSpacing.medium)
            .padding(.vertical, FlotillaSpacing.small)
            .background(FlotillaColors.surface)

            Divider()

            Spacer()

            ZStack {
                Circle()
                    .fill(FlotillaColors.surfaceElevated)
                    .frame(width: 84, height: 84)
                MaterialFileIcon(url: node.url, size: 44)
            }

            VStack(spacing: FlotillaSpacing.xSmall) {
                Text(node.name)
                    .font(.title2.weight(.semibold))
                    .foregroundStyle(FlotillaColors.textPrimary)

                if let size = viewModel.fileSizeString {
                    Text("\(size) · Binary / Uneditable File")
                        .font(FlotillaTypography.caption.monospaced())
                        .foregroundStyle(FlotillaColors.textTertiary)
                }

                Text("This file cannot be displayed in the text editor.")
                    .font(FlotillaTypography.callout)
                    .foregroundStyle(FlotillaColors.textSecondary)
                    .padding(.top, 4)
            }

            HStack(spacing: FlotillaSpacing.medium) {
                Button {
                    NSWorkspace.shared.open(node.url)
                } label: {
                    Label("Open in Default App", systemImage: "arrow.up.forward.app")
                }
                .buttonStyle(.borderedProminent)

                Button {
                    NSWorkspace.shared.activateFileViewerSelecting([node.url])
                } label: {
                    Label("Reveal in Finder", systemImage: "folder")
                }
                .buttonStyle(.bordered)
            }
            .padding(.top, FlotillaSpacing.small)

            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(FlotillaColors.terminalCanvas)
    }
}
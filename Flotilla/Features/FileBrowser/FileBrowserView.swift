import SwiftUI
import AppKit
import SessionKit
import DesignSystem

/// Files tab for workspace roots and sessions: file tree on the left,
/// Monaco-backed code editor on the right with rendered Markdown preview toggle,
/// image previews, binary file handlers, and file operations.
struct FileBrowserView: View {
    let rootURL: URL
    @Bindable var viewModel: FileBrowserViewModel
    @Environment(\.editorFontSize) private var editorFontSize

    @State private var markdownMode: MarkdownMode = .preview
    @State private var searchText = ""
    @State private var isShowingNewFileDialog = false
    @State private var isShowingNewFolderDialog = false
    @State private var isShowingRenameDialog = false
    @State private var isShowingDeleteDialog = false
    @State private var targetFolderURL: URL?
    @State private var targetNodeToRename: FileNode?
    @State private var targetNodeToDelete: FileNode?
    @State private var newFileName = ""
    @State private var newFolderName = ""
    @State private var renameText = ""
    @State private var creationError: String?

    enum MarkdownMode: String, CaseIterable, Identifiable {
        case preview = "Preview"
        case edit = "Edit"

        var id: Self { self }
    }

    init(viewModel: FileBrowserViewModel) {
        self.rootURL = viewModel.rootURL
        self._viewModel = Bindable(wrappedValue: viewModel)
    }

    var body: some View {
        HSplitView {
            fileTreePane
                .frame(minWidth: 220, idealWidth: 260, maxWidth: 360)
                .frame(maxHeight: .infinity)
            editorPane
                .frame(minWidth: 400, maxWidth: .infinity)
                .frame(maxHeight: .infinity)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .flotillaLiquidSurface(FlotillaColors.canvas, glassTintOpacity: FlotillaGlassTint.detail)
        .task(id: rootURL) {
            await viewModel.loadIfNeeded()
        }
        .alert("New File", isPresented: $isShowingNewFileDialog) {
            TextField("File name (e.g. README.md, .env, main.ts)", text: $newFileName)
            Button("Create") {
                createNewFile()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Enter a name for the new file to create in this workspace.")
        }
        .alert("New Folder", isPresented: $isShowingNewFolderDialog) {
            TextField("Folder name (e.g. components, utils)", text: $newFolderName)
            Button("Create") {
                createNewFolder()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Enter a name for the new directory.")
        }
        .alert("Rename", isPresented: $isShowingRenameDialog) {
            TextField("New name", text: $renameText)
            Button("Rename") {
                if let target = targetNodeToRename {
                    renameItem(node: target, newName: renameText)
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            if let target = targetNodeToRename {
                Text("Rename \"\(target.name)\" to:")
            }
        }
        .alert("Delete", isPresented: $isShowingDeleteDialog) {
            Button("Delete", role: .destructive) {
                if let target = targetNodeToDelete {
                    deleteItem(node: target)
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            if let target = targetNodeToDelete {
                Text("Are you sure you want to delete \"\(target.name)\"? This item will be moved to the Trash.")
            }
        }
        .accessibilityIdentifier(AXID.fileBrowser.rawValue)
    }

    private func createNewFile() {
        let trimmed = newFileName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        let folder = targetFolderURL ?? rootURL
        let targetURL = folder.appendingPathComponent(trimmed)
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
        } catch {
            creationError = error.localizedDescription
        }
    }

    private func createNewFolder() {
        let trimmed = newFolderName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        let folder = targetFolderURL ?? rootURL
        let targetURL = folder.appendingPathComponent(trimmed)
        do {
            try FileManager.default.createDirectory(at: targetURL, withIntermediateDirectories: true)
            Task {
                await viewModel.refresh()
            }
        } catch {
            creationError = error.localizedDescription
        }
    }

    private func renameItem(node: FileNode, newName: String) {
        let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != node.name else { return }

        let parent = node.url.deletingLastPathComponent()
        let newURL = parent.appendingPathComponent(trimmed)
        do {
            try FileManager.default.moveItem(at: node.url, to: newURL)
            Task {
                await viewModel.refresh()
                if viewModel.selectedNode?.id == node.id {
                    let renamedNode = FileNode(url: newURL, isDirectory: node.isDirectory)
                    await viewModel.select(renamedNode)
                }
            }
        } catch {
            creationError = error.localizedDescription
        }
    }

    private func deleteItem(node: FileNode) {
        do {
            try FileManager.default.trashItem(at: node.url, resultingItemURL: nil)
            Task {
                if viewModel.selectedNode?.id == node.id {
                    viewModel.selectedNode = nil
                    viewModel.content = ""
                }
                await viewModel.refresh()
            }
        } catch {
            try? FileManager.default.removeItem(at: node.url)
            Task {
                if viewModel.selectedNode?.id == node.id {
                    viewModel.selectedNode = nil
                    viewModel.content = ""
                }
                await viewModel.refresh()
            }
        }
    }

    // MARK: - File Tree Pane

    private var fileTreePane: some View {
        VStack(spacing: 0) {
            fileTreeHeader
            searchBar
            Divider()

            if viewModel.isLoading && viewModel.nodes.isEmpty {
                ProgressView("Loading files…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let errorMessage = viewModel.errorMessage, viewModel.nodes.isEmpty {
                ContentUnavailableView(
                    "Error Loading Files",
                    systemImage: "exclamationmark.triangle",
                    description: Text(errorMessage)
                )
                .accessibilityIdentifier("FileBrowser.Error")
            } else if viewModel.nodes.isEmpty {
                ContentUnavailableView(
                    "Empty Folder",
                    systemImage: "folder",
                    description: Text("No files found in this workspace.")
                )
                .accessibilityIdentifier("FileBrowser.Empty")
            } else {
                List {
                    OutlineGroup(filteredNodes, children: \.children) { node in
                        Button {
                            if !node.isDirectory {
                                Task { await viewModel.select(node) }
                            }
                        } label: {
                            HStack(spacing: 7) {
                                MaterialFileIcon(node: node, size: 17)
                                Text(node.name)
                                    .font(.system(size: 12, weight: .medium, design: .monospaced))
                                    .foregroundStyle(node.name.hasPrefix(".") ? FlotillaColors.textSecondary : FlotillaColors.textPrimary)
                                    .lineLimit(1)
                            }
                            .padding(.vertical, 0.5)
                            .contentShape(.rect)
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("FileBrowser.Row-\(node.name)")
                        .listRowBackground(
                            RoundedRectangle(cornerRadius: FlotillaRadius.control, style: .continuous)
                                .fill(viewModel.selectedNode?.id == node.id ? FlotillaColors.accent.opacity(0.12) : Color.clear)
                        )
                        .contextMenu {
                            Button {
                                targetFolderURL = node.isDirectory ? node.url : node.url.deletingLastPathComponent()
                                newFileName = ""
                                isShowingNewFileDialog = true
                            } label: {
                                Label("New File", systemImage: "doc.badge.plus")
                            }

                            Button {
                                targetFolderURL = node.isDirectory ? node.url : node.url.deletingLastPathComponent()
                                newFolderName = ""
                                isShowingNewFolderDialog = true
                            } label: {
                                Label("New Folder", systemImage: "folder.badge.plus")
                            }

                            Divider()

                            Button {
                                targetNodeToRename = node
                                renameText = node.name
                                isShowingRenameDialog = true
                            } label: {
                                Label("Rename…", systemImage: "pencil")
                            }

                            Button {
                                NSPasteboard.general.clearContents()
                                NSPasteboard.general.setString(node.url.path, forType: .string)
                            } label: {
                                Label("Copy Path", systemImage: "doc.on.doc")
                            }

                            Button(role: .destructive) {
                                targetNodeToDelete = node
                                isShowingDeleteDialog = true
                            } label: {
                                Label("Delete", systemImage: "trash")
                            }
                        }
                    }
                }
                .listStyle(.sidebar)
                .scrollContentBackground(.hidden)
                .accessibilityIdentifier("FileBrowser.List")
            }
        }
        .flotillaInspectorSurface()
    }

    private var fileTreeHeader: some View {
        HStack(spacing: FlotillaSpacing.small) {
            Label(rootURL.lastPathComponent, systemImage: "folder")
                .font(.headline)
                .foregroundStyle(FlotillaColors.textPrimary)
                .lineLimit(1)

            Spacer()

            Button {
                newFileName = ""
                isShowingNewFileDialog = true
            } label: {
                Image(systemName: "plus")
                    .font(.system(size: 11, weight: .bold))
            }
            .buttonStyle(.plain)
            .help("New File (⌘N)")
            .keyboardShortcut("n", modifiers: .command)
            .accessibilityIdentifier("FileBrowser.NewFileButton")

            Button {
                Task { await viewModel.refresh() }
            } label: {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 11))
            }
            .buttonStyle(.plain)
            .help("Refresh files")
            .accessibilityIdentifier("FileBrowser.RefreshButton")
        }
        .padding(.horizontal, FlotillaSpacing.medium)
        .padding(.top, FlotillaSpacing.small + 2)
        .padding(.bottom, 2)
        .background(FlotillaColors.surface)
    }

    private var searchBar: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(FlotillaColors.textTertiary)
                .font(.system(size: FlotillaIconSize.small))
            TextField("Filter files…", text: $searchText)
                .textFieldStyle(.plain)
                .font(.system(size: 11.5, design: .monospaced))
                .autocorrectionDisabled()
                .textContentType(nil)
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
        .padding(FlotillaSpacing.small)
    }

    private var filteredNodes: [FileNode] {
        guard !searchText.isEmpty else { return viewModel.nodes }
        return filterNodes(viewModel.nodes, query: searchText)
    }

    private func filterNodes(_ nodes: [FileNode], query: String) -> [FileNode] {
        var filtered: [FileNode] = []
        for node in nodes {
            if node.isDirectory {
                let matchingChildren = filterNodes(node.children ?? [], query: query)
                if !matchingChildren.isEmpty || node.name.localizedCaseInsensitiveContains(query) {
                    var copy = node
                    copy.children = matchingChildren
                    filtered.append(copy)
                }
            } else if node.name.localizedCaseInsensitiveContains(query) {
                filtered.append(node)
            }
        }
        return filtered
    }

    // MARK: - Editor Pane

    @ViewBuilder
    private var editorPane: some View {
        if let node = viewModel.selectedNode {
            VStack(spacing: 0) {
                editorHeader(node)
                Divider()

                if let error = viewModel.errorMessage {
                    Text(error)
                        .font(.system(size: 11.5, design: .monospaced))
                        .foregroundStyle(Color.red)
                        .padding(.horizontal, FlotillaSpacing.medium)
                        .padding(.vertical, 4)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color.red.opacity(0.08))
                        .accessibilityIdentifier("FileBrowser.ErrorMessage")
                }

                if viewModel.isBinaryOrUnopenable {
                    let ext = node.url.pathExtension.lowercased()
                    if ["png", "jpg", "jpeg", "gif", "webp", "ico", "bmp", "tiff", "heic", "svg"].contains(ext) {
                        imagePreviewView(node: node)
                    } else {
                        binaryFilePlaceholderView(node: node)
                    }
                } else if ["md", "markdown", "mdx"].contains(node.url.pathExtension.lowercased()) {
                    if markdownMode == .preview {
                        ScrollView {
                            MarkdownView(markdown: viewModel.content)
                                .padding(FlotillaSpacing.large)
                        }
                        .flotillaLiquidSurface(FlotillaColors.canvas, glassTintOpacity: FlotillaGlassTint.detail)
                        .accessibilityIdentifier("FileBrowser.MarkdownEditor")
                        .accessibilityLabel("Markdown editor for \(node.name)")
                    } else {
                        MonacoHostView(
                            content: $viewModel.content,
                            language: .markdown,
                            fileURL: node.url,
                            fontSize: editorFontSize,
                            onSave: { _ in
                                Task { await viewModel.save() }
                            }
                        )
                        .accessibilityIdentifier("FileBrowser.Editor")
                    }
                } else {
                    MonacoHostView(
                        content: $viewModel.content,
                        language: MonacoLanguage.from(url: node.url),
                        fileURL: node.url,
                        fontSize: editorFontSize,
                        onSave: { _ in
                            Task { await viewModel.save() }
                        }
                    )
                    .accessibilityIdentifier("FileBrowser.Editor")
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(FlotillaColors.terminalCanvas)
        } else {
            ContentUnavailableView(
                "No File Selected",
                systemImage: "doc.text.magnifyingglass",
                description: Text("Choose a file from the tree on the left to inspect or edit.")
            )
            .accessibilityIdentifier("FileBrowser.NoSelection")
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(FlotillaColors.terminalCanvas)
        }
    }

    private func editorHeader(_ node: FileNode) -> some View {
        HStack(spacing: FlotillaSpacing.small) {
            MaterialFileIcon(node: node, size: 19)

            VStack(alignment: .leading, spacing: 1) {
                Text(node.name)
                    .font(.system(size: 13, weight: .semibold, design: .monospaced))
                    .foregroundStyle(FlotillaColors.textPrimary)
                Text(node.url.path)
                    .font(.system(size: 10.5, design: .monospaced))
                    .foregroundStyle(FlotillaColors.textTertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)
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
            .help("Open in associated default application")

            if !viewModel.isBinaryOrUnopenable {
                if ["md", "markdown", "mdx"].contains(node.url.pathExtension.lowercased()) {
                    Picker("Mode", selection: $markdownMode) {
                        ForEach(MarkdownMode.allCases) { mode in
                            Text(mode.rawValue).tag(mode)
                        }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .frame(width: 130)
                }

                if let message = viewModel.message {
                    Label(
                        message,
                        systemImage: message.hasPrefix("Saved") ? "checkmark.circle.fill" : "exclamationmark.triangle.fill"
                    )
                    .font(FlotillaTypography.caption2)
                    .foregroundStyle(message.hasPrefix("Saved") ? FlotillaColors.success : Color.red)
                }

                Button("Save") {
                    Task {
                        await viewModel.save()
                    }
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .keyboardShortcut("s", modifiers: .command)
                .disabled(viewModel.isSaving)
                .accessibilityIdentifier("FileBrowser.SaveButton")
            }
        }
        .padding(.horizontal, FlotillaSpacing.medium)
        .padding(.vertical, FlotillaSpacing.small)
        .background(FlotillaColors.surface)
    }

    // MARK: - Binary & Media Previews

    private func imagePreviewView(node: FileNode) -> some View {
        VStack(spacing: FlotillaSpacing.medium) {
            Spacer()
            if let image = NSImage(contentsOf: node.url) {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(maxWidth: 600, maxHeight: 460)
                    .background(FlotillaColors.surfaceElevated)
                    .clipShape(RoundedRectangle(cornerRadius: FlotillaRadius.card))
                    .overlay(
                        RoundedRectangle(cornerRadius: FlotillaRadius.card)
                            .strokeBorder(FlotillaColors.separator, lineWidth: 1)
                    )
                    .shadow(color: Color.black.opacity(0.2), radius: 12, y: 6)
            } else {
                MaterialFileIcon(url: node.url, size: 64)
            }

            VStack(spacing: 4) {
                if let size = viewModel.fileSizeString {
                    Text(size)
                        .font(FlotillaTypography.caption.monospaced())
                        .foregroundStyle(FlotillaColors.textSecondary)
                }
            }

            HStack(spacing: FlotillaSpacing.medium) {
                Button {
                    NSWorkspace.shared.open(node.url)
                } label: {
                    Label("Open in Default App", systemImage: "arrow.up.forward.app")
                }
                .buttonStyle(.borderedProminent)
                .tint(FlotillaColors.accent)
                .controlSize(.regular)

                Button {
                    NSWorkspace.shared.activateFileViewerSelecting([node.url])
                } label: {
                    Label("Reveal in Finder", systemImage: "folder")
                }
                .buttonStyle(.bordered)
                .controlSize(.regular)
            }
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(FlotillaColors.terminalCanvas)
    }

    private func binaryFilePlaceholderView(node: FileNode) -> some View {
        VStack(spacing: FlotillaSpacing.large) {
            Spacer()

            ZStack {
                Circle()
                    .fill(FlotillaColors.surfaceElevated)
                    .frame(width: 96, height: 96)
                MaterialFileIcon(url: node.url, size: 48)
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

                Text("This file cannot be displayed in the built-in text editor.")
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
                .tint(FlotillaColors.accent)
                .controlSize(.regular)

                Button {
                    NSWorkspace.shared.activateFileViewerSelecting([node.url])
                } label: {
                    Label("Reveal in Finder", systemImage: "folder")
                }
                .buttonStyle(.bordered)
                .controlSize(.regular)
            }
            .padding(.top, FlotillaSpacing.small)

            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(FlotillaColors.terminalCanvas)
    }
}

typealias ProjectFilesView = FileBrowserView

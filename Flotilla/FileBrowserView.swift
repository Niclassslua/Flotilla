import SwiftUI
import DesignSystem

struct FileBrowserView: View {
    let rootURL: URL
    @State private var viewModel: FileBrowserViewModel
    @FocusState private var isEditorFocused: Bool

    init(rootURL: URL, service: any WorkspaceFileServicing = WorkspaceFileService()) {
        self.rootURL = rootURL
        _viewModel = State(initialValue: FileBrowserViewModel(root: rootURL, service: service))
    }

    var body: some View {
        HSplitView {
            fileNavigator
                .frame(minWidth: 210, idealWidth: 260, maxWidth: 360)
            editor
                .frame(minWidth: 360)
        }
        .task(id: rootURL) { await viewModel.refresh() }
    }

    private var fileNavigator: some View {
        VStack(spacing: 0) {
            HStack {
                Label(rootURL.lastPathComponent, systemImage: "folder")
                    .font(.headline)
                    .lineLimit(1)
                Spacer()
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
            .background(FlotillaColors().surface)

            Divider()

            if viewModel.isLoading && viewModel.nodes.isEmpty {
                ProgressView("Loading files…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(FlotillaColors().surface)
            } else if let errorMessage = viewModel.errorMessage, viewModel.nodes.isEmpty {
                // Show error state when there's an error and no files loaded
                ContentUnavailableView(
                    "Error Loading Files",
                    systemImage: "exclamationmark.triangle",
                    description: Text(errorMessage)
                )
                .accessibilityIdentifier("FileBrowser.Error")
                .background(FlotillaColors().surface)
            } else if viewModel.nodes.isEmpty {
                ContentUnavailableView(
                    "No Files",
                    systemImage: "folder",
                    description: Text("This worktree is empty.")
                )
                .accessibilityIdentifier("FileBrowser.Empty")
                .background(FlotillaColors().surface)
            } else {
                List {
                    OutlineGroup(viewModel.nodes, children: \.children) { node in
                        Button {
                            Task { await viewModel.select(node) }
                        } label: {
                            Label(node.name, systemImage: node.isDirectory ? "folder" : icon(for: node.url))
                                .foregroundStyle(.primary)
                                .contentShape(.rect)
                        }
                        .buttonStyle(.plain)
                        .disabled(node.isDirectory)
                        .listRowBackground(
                            RoundedRectangle(cornerRadius: FlotillaRadius.control, style: .continuous)
                                .fill(viewModel.selectedNode == node ? FlotillaColors().accent.opacity(0.09) : .clear)
                        )
                        .accessibilityIdentifier("FileBrowser.Row-\(node.name)")
                    }
                }
                .listStyle(.sidebar)
                .scrollContentBackground(.hidden)
                .background(FlotillaColors().surface)
                .accessibilityIdentifier("FileBrowser.List")
            }
        }
        .background(FlotillaColors().surface)
    }

    @ViewBuilder
    private var editor: some View {
        @Bindable var bindableViewModel = viewModel
        if let node = viewModel.selectedNode {
            VStack(spacing: 0) {
                HStack(spacing: 10) {
                    Image(systemName: icon(for: node.url))
                        .foregroundStyle(.secondary)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(node.name)
                            .font(.headline)
                        Text(node.url.path.replacingOccurrences(of: rootURL.path + "/", with: ""))
                            .font(.caption.monospaced())
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
                .background(FlotillaColors().surface)

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

                TextEditor(text: $bindableViewModel.content)
                    .font(.system(.body, design: .monospaced))
                    .scrollContentBackground(.hidden)
                    .padding(FlotillaSpacing.small)
                    .background(FlotillaColors().terminalCanvas)
                    .focused($isEditorFocused)
                    .accessibilityIdentifier("FileBrowser.Editor")
                    .accessibilityLabel("File editor for \(node.name)")
            }
        } else {
            ContentUnavailableView(
                "Select a File",
                systemImage: "doc.text.magnifyingglass",
                description: Text("Open a text file to inspect or edit it in place.")
            )
            .accessibilityIdentifier("FileBrowser.NoSelection")
            .background(FlotillaColors().terminalCanvas)
        }
    }

    private func icon(for url: URL) -> String {
        switch url.pathExtension.lowercased() {
        case "swift": "swift"
        case "md": "doc.richtext"
        case "json", "yml", "yaml": "curlybraces"
        default: "doc.text"
        }
    }
}

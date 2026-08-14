import SwiftUI

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
            .padding(.horizontal, 12)
            .padding(.vertical, 10)

            Divider()

            if viewModel.isLoading && viewModel.nodes.isEmpty {
                ProgressView("Loading files…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if viewModel.nodes.isEmpty {
                ContentUnavailableView(
                    "No Files",
                    systemImage: "folder",
                    description: Text(viewModel.errorMessage ?? "This worktree is empty.")
                )
                .accessibilityIdentifier("FileBrowser.Empty")
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
                        .accessibilityIdentifier("FileBrowser.Row-\(node.name)")
                    }
                }
                .listStyle(.sidebar)
                .accessibilityIdentifier("FileBrowser.List")
            }
        }
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
                .padding(.horizontal, 14)
                .padding(.vertical, 9)
                .background(.thinMaterial)

                if let errorMessage = viewModel.errorMessage {
                    Text(errorMessage)
                        .font(.caption)
                        .foregroundStyle(.red)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 7)
                        .background(Color.red.opacity(0.08))
                }

                Divider()

                TextEditor(text: $bindableViewModel.content)
                    .font(.system(.body, design: .monospaced))
                    .padding(7)
                    .focused($isEditorFocused)
                    .accessibilityIdentifier("FileBrowser.Editor")
            }
        } else {
            ContentUnavailableView(
                "Select a File",
                systemImage: "doc.text.magnifyingglass",
                description: Text("Open a text file to inspect or edit it in place.")
            )
            .accessibilityIdentifier("FileBrowser.NoSelection")
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

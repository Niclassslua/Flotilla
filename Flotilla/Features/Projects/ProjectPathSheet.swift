import SwiftUI
import AppKit
import DesignSystem

enum ProjectSheetType: String, Identifiable {
    case add
    case importWorkspace

    var id: Self { self }
}

struct ProjectPathSheet: View {
    @Environment(\.dismiss) private var dismiss

    let importsWorkspace: Bool
    let addPaths: ([URL]) -> Void
    @State private var path = ""

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: importsWorkspace ? "square.stack.3d.down.right" : "folder.badge.plus")
                    .font(.system(size: 24, weight: .medium))
                    .foregroundStyle(FlotillaColors.accent)
                    .frame(width: 40, height: 40)
                    .background(FlotillaColors.accent.opacity(0.12), in: RoundedRectangle(cornerRadius: 7))
                VStack(alignment: .leading, spacing: 3) {
                    Text(importsWorkspace ? "Import a workspace" : "Add a project")
                        .font(.title3.weight(.semibold))
                    Text(importsWorkspace
                         ? "Scan one folder for local Git projects and add them together."
                         : "Add a local checkout to your Flotilla project library.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }
            .padding(20)

            Divider()

            VStack(alignment: .leading, spacing: 8) {
                Text(importsWorkspace ? "Workspace path" : "Path")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                HStack(spacing: 8) {
                    TextField(importsWorkspace ? "/path/to/workspace" : "/path/to/project", text: $path)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(.body, design: .monospaced))
                    Button("Browse…", action: browse)
                }
                if importsWorkspace {
                    Text("Immediate child folders containing a .git directory or file will be imported.")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
            }
            .padding(20)

            Divider()

            HStack {
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Button(importsWorkspace ? "Scan" : "Add Project") {
                    addPaths(resolvedPaths)
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(path.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || resolvedPaths.isEmpty)
            }
            .padding(16)
        }
        .frame(width: 520)
        .background(FlotillaColors.surface)
    }

    private var resolvedPaths: [URL] {
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }
        let root = URL(fileURLWithPath: trimmed).standardizedFileURL
        guard importsWorkspace else { return [root] }
        guard let children = try? FileManager.default.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }
        return children.filter { child in
            guard !WorkspaceFileService.isTCCProtected(child) else { return false }
            var isDirectory: ObjCBool = false
            let gitPath = child.appendingPathComponent(".git").path
            return FileManager.default.fileExists(atPath: child.path, isDirectory: &isDirectory)
                && isDirectory.boolValue
                && FileManager.default.fileExists(atPath: gitPath)
        }
    }

    private func browse() {
        if ProcessInfo.processInfo.environment["UI_TESTING"] == "1" {
            path = AppEnvironment.uiTestFixtureProjectPath.path
            return
        }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = importsWorkspace ? "Choose Workspace" : "Choose Project"
        if panel.runModal() == .OK, let url = panel.url { path = url.path }
    }
}

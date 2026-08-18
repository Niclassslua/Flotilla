import SwiftUI
import SessionKit
import DesignSystem

/// Compact project card used by the Projects workspace. Extracted verbatim
/// from `HomeDashboardView.swift` when the home screen moved to `Flotilla/Home/`
/// and stopped using it — `ProjectsWorkspaceView` is its only remaining caller.
///
/// Note: the context menu still carries three no-op buttons inherited from the
/// original. They belong to the Projects workspace, not the home redesign, so
/// they are left untouched here rather than fixed out of scope.
struct ProjectCompactCard: View {
    let project: Project
    let sessionCount: Int

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                ZStack {
                    RoundedRectangle(cornerRadius: 6)
                        .fill(FlotillaColors.accent.opacity(0.12))
                    Image(systemName: "folder.fill")
                        .foregroundStyle(FlotillaColors.accent)
                }
                .frame(width: 32, height: 32)
                Spacer()
                Menu {
                    Button("Open") { }
                    Button("Reveal in Finder") {
                        NSWorkspace.shared.activateFileViewerSelecting([project.rootPath])
                    }
                    Button("New Session Here") { }
                    Divider()
                    Button("Remove Project", role: .destructive) { }
                } label: {
                    Image(systemName: "ellipsis")
                        .foregroundStyle(.secondary)
                }
                .menuStyle(.borderlessButton)
            }
            Text(project.name)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(.primary)
                .lineLimit(1)
            Text(project.rootPath.path)
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
            Divider()
            HStack {
                Label("\(sessionCount) session\(sessionCount == 1 ? "" : "s")", systemImage: "terminal")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Text(sessionCount > 0 ? "Active" : "Ready")
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(sessionCount > 0 ? FlotillaColors.statusWorking : .secondary)
            }
        }
        .padding(15)
        .frame(maxWidth: .infinity, minHeight: 154, alignment: .leading)
        .background(FlotillaColors.surface, in: RoundedRectangle(cornerRadius: 8))
        .overlay {
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(FlotillaColors.separator)
        }
        .contentShape(.rect)
    }
}

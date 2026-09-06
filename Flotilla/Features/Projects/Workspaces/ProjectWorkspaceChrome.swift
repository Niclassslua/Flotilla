import SwiftUI
import SessionKit
import GitKit
import DesignSystem

/// The accessibility identifier the workspace puts on whatever control opens a
/// given surface — the UI tests wait for `ProjectDetail.ModeTab-Git` after
/// selecting a project.
func projectSurfaceAXID(_ tab: ProjectDetailView.ProjectTab) -> String {
    "ProjectDetail.ModeTab-\(tab.title)"
}

/// Shown above a routed-through surface (Git / Files / Skills / Rules) as a
/// breadcrumb back to the activity feed.
struct SurfaceReturnBar: View {
    @Environment(\.workspaceNavigator) private var navigator
    let context: ProjectWorkspaceContext
    let tab: ProjectDetailView.ProjectTab

    var body: some View {
        HStack(spacing: FlotillaSpacing.small) {
            Button {
                withAnimation(FlotillaMotion.fast.curve) {
                    navigator.setProjectTab(.overview, for: context.project.id)
                }
            } label: {
                Label("Overview", systemImage: "chevron.left")
                    .font(FlotillaTypography.caption.weight(.medium))
            }
            .buttonStyle(.plain)
            .foregroundStyle(FlotillaColors.textSecondary)
            .accessibilityIdentifier("Project.ReturnToOverview")

            Text("/")
                .font(FlotillaTypography.caption)
                .foregroundStyle(FlotillaColors.textTertiary)

            Text(tab.title)
                .font(FlotillaTypography.caption.weight(.semibold))
                .foregroundStyle(FlotillaColors.textPrimary)

            Spacer()
        }
        .padding(.horizontal, FlotillaSpacing.large)
        .padding(.vertical, FlotillaSpacing.small)
        .background(FlotillaColors.surface)
    }
}

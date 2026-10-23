import SwiftUI
import SessionKit
import GitKit
import DesignSystem

/// Shown above a routed-through surface (Git / Files / Skills / Rules) as a
/// breadcrumb back to the activity feed.
struct SurfaceReturnBar: View {
    @Environment(\.workspaceNavigator) private var navigator
    let context: ProjectWorkspaceContext
    let tool: ProjectTool

    var body: some View {
        HStack(spacing: FlotillaSpacing.small) {
            Button {
                withAnimation(FlotillaMotion.fast.curve) {
                    navigator.selection = .project(context.project.id)
                }
            } label: {
                Label("Overview", systemImage: "chevron.left")
                    .font(FlotillaTypography.caption.weight(.medium))
            }
            .buttonStyle(.plain)
            .foregroundStyle(FlotillaColors.textSecondary)
            .accessibilityIdentifier(AXID.projectReturnToOverview.rawValue)

            Text("/")
                .font(FlotillaTypography.caption)
                .foregroundStyle(FlotillaColors.textTertiary)

            Text(context.project.name)
                .font(FlotillaTypography.caption.weight(.medium))
                .foregroundStyle(FlotillaColors.textSecondary)
                .lineLimit(1)

            Text("/")
                .font(FlotillaTypography.caption)
                .foregroundStyle(FlotillaColors.textTertiary)

            Text(tool.title)
                .font(FlotillaTypography.caption.weight(.semibold))
                .foregroundStyle(FlotillaColors.textPrimary)

            Spacer()
        }
        .padding(.horizontal, FlotillaSpacing.large)
        .padding(.vertical, FlotillaSpacing.small)
        .background(FlotillaColors.surface)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(context.project.name), \(tool.title)")
    }
}

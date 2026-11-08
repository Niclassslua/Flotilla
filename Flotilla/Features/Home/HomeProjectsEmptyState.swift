import SwiftUI
import DesignSystem

struct HomeProjectsEmptyState: View {
    let addProject: () -> Void
    let importWorkspace: () -> Void

    var body: some View {
        HStack(spacing: 32) {
            VStack(alignment: .leading, spacing: 16) {
                eyebrow("YOUR WORK STARTS HERE")
                title("Bring your projects aboard")
                description("Add a local repository to see its branches, changes, and sessions together in one place.")
                actions
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            illustration
                .frame(width: 200, height: 150)
                .accessibilityHidden(true)
        }
        .padding(32)
        .frame(maxWidth: .infinity)
        .flotillaLiquidSurface(
            FlotillaColors.surface,
            cornerRadius: FlotillaRadius.modal,
            glassTintOpacity: FlotillaGlassTint.elevated
        )
    }

    private func eyebrow(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 10, weight: .bold, design: .monospaced))
            .tracking(1.2)
            .foregroundStyle(FlotillaColors.accent)
    }

    private func title(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 23, weight: .semibold, design: .rounded))
            .foregroundStyle(FlotillaColors.textPrimary)
    }

    private func description(_ text: String) -> some View {
        Text(text)
            .font(FlotillaTypography.callout)
            .foregroundStyle(FlotillaColors.textSecondary)
            .fixedSize(horizontal: false, vertical: true)
    }

    private var actions: some View {
        HStack(spacing: 10) {
            Button(action: addProject) {
                Label("Add Project", systemImage: "plus")
            }
            .buttonStyle(.borderedProminent)
            .tint(FlotillaColors.accent)
            .accessibilityIdentifier("Projects.ImportButton")
            Button("Import Workspace", action: importWorkspace)
                .buttonStyle(.bordered)
                .help("Scan a folder for local Git repositories")
        }
        .controlSize(.regular)
    }

    private var illustration: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 16)
                .stroke(FlotillaColors.separator, style: StrokeStyle(lineWidth: 1, dash: [5, 5]))
                .frame(width: 172, height: 116)
                .rotationEffect(.degrees(-7))
            RoundedRectangle(cornerRadius: 14)
                .fill(FlotillaColors.surfaceElevated)
                .frame(width: 164, height: 108)
                .overlay(RoundedRectangle(cornerRadius: 14).stroke(FlotillaColors.separator))
                .rotationEffect(.degrees(5))
            Image(systemName: "folder.badge.plus")
                .font(.system(size: 40, weight: .light))
                .foregroundStyle(FlotillaColors.accent)
        }
    }
}

#if DEBUG
#Preview("Launchpad") {
    HomeProjectsEmptyState(addProject: {}, importWorkspace: {})
        .frame(width: 900).padding().background(FlotillaColors.canvas)
}
#endif

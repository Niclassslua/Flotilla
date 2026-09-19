import SwiftUI
import SessionKit
import DesignSystem

/// Glass in the app; an opaque surface when rendered offscreen, where
/// `ImageRenderer` can't sample what's behind the glass.
private struct HomeWidgetOpaqueSurfaceKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    var homeWidgetOpaqueSurface: Bool {
        get { self[HomeWidgetOpaqueSurfaceKey.self] }
        set { self[HomeWidgetOpaqueSurfaceKey.self] = newValue }
    }
}

/// A resolved subtitle for non-default settings, e.g. "flotilla · 30d".
struct HomeWidgetConfigSummary {
    var projectName: String?
    var timeWindowLabel: String?
    var agentLabel: String?

    var text: String? {
        let parts = [projectName, timeWindowLabel, agentLabel].compactMap { $0 }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }
}

enum HomeWidgetCardMetrics {
    static let padding: CGFloat = FlotillaSpacing.large - 2
    static let radius: CGFloat = FlotillaRadius.modal + 4
    static var shape: RoundedRectangle { RoundedRectangle(cornerRadius: radius, style: .continuous) }
}

/// The chrome every widget renders inside: glass card and title row. It
/// fills exactly the frame the grid gives it and clips anything beyond, so
/// a widget can never grow its row. Edit controls live in `HomeWidgetView`,
/// which owns the gestures they drive.
struct HomeWidgetCard<Content: View>: View {
    let kind: HomeWidgetKind
    var count: Int?
    var configSummary = HomeWidgetConfigSummary()
    var isEditing = false
    @ViewBuilder let content: Content

    @Environment(\.homeWidgetOpaqueSurface) private var opaque

    var body: some View {
        VStack(alignment: .leading, spacing: FlotillaSpacing.small + 2) {
            header
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .allowsHitTesting(!isEditing)
        }
        .padding(HomeWidgetCardMetrics.padding)
        // `minWidth/minHeight: 0` make the frame take the proposed size
        // outright instead of growing to fit oversized content.
        .frame(minWidth: 0, maxWidth: .infinity, minHeight: 0, maxHeight: .infinity, alignment: .topLeading)
        .background {
            if opaque {
                HomeWidgetCardMetrics.shape.fill(FlotillaColors.surfaceElevated.opacity(0.92))
            } else {
                Color.clear.glassEffect(.regular, in: HomeWidgetCardMetrics.shape)
            }
        }
        .overlay {
            HomeWidgetCardMetrics.shape.strokeBorder(
                FlotillaColors.textPrimary.opacity(isEditing ? 0.16 : 0.08),
                lineWidth: FlotillaBorderWidth.thin
            )
        }
        .clipShape(HomeWidgetCardMetrics.shape)
        // The glass background is `Color.clear` to hit testing; without this
        // a click between the content's own controls lands on nothing, so
        // neither dragging nor the context menu would ever start.
        .contentShape(HomeWidgetCardMetrics.shape)
        .accessibilityIdentifier(AXID.homeWidget.rawValue + kind.rawValue)
    }

    private var header: some View {
        HStack(spacing: 5) {
            Image(systemName: kind.glyph)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(FlotillaColors.accent)
            Text(kind.title)
                .font(.system(size: 13, weight: .semibold, design: .rounded))
                .foregroundStyle(FlotillaColors.textPrimary)
                .lineLimit(1)
                .layoutPriority(1)
            if let count, count > 0 {
                Text("\(count)")
                    .font(.system(size: 12, weight: .medium, design: .rounded).monospacedDigit())
                    .foregroundStyle(FlotillaColors.textTertiary)
            }
            if let text = configSummary.text {
                Text("· \(text)")
                    .font(FlotillaTypography.caption2)
                    .foregroundStyle(FlotillaColors.textTertiary)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .frame(height: 16)
    }
}

/// Shown in place of a widget's content when its configured project no
/// longer exists.
struct HomeWidgetProjectRemovedState: View {
    let onPick: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: FlotillaSpacing.small) {
            Spacer(minLength: 0)
            Image(systemName: "questionmark.folder")
                .font(.system(size: 20, weight: .regular))
                .foregroundStyle(FlotillaColors.textTertiary)
            Text("Project removed")
                .font(FlotillaTypography.callout.weight(.medium))
                .foregroundStyle(FlotillaColors.textSecondary)
            Button("Choose a project…", action: onPick)
                .font(FlotillaTypography.caption)
                .buttonStyle(.plain)
                .foregroundStyle(FlotillaColors.accent)
            Spacer(minLength: 0)
        }
    }
}

/// Shown when a widget's data is present but empty — the widget stays in
/// place rather than collapsing, so the grid never reflows under you.
struct HomeWidgetAllClearState: View {
    var message = "All clear"

    var body: some View {
        VStack(spacing: 4) {
            Spacer(minLength: 0)
            Image(systemName: "checkmark.circle")
                .font(.system(size: 20, weight: .regular))
                .foregroundStyle(FlotillaColors.statusReady)
            Text(message)
                .font(FlotillaTypography.callout)
                .foregroundStyle(FlotillaColors.textSecondary)
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity)
    }
}

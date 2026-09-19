import SwiftUI
import SessionKit
import DesignSystem

/// Whether the glass background renders normally or as an opaque fallback —
/// carried over from the prototypes, where `ImageRenderer` can't sample the
/// glass. Kept because the same limitation applies to any future offscreen
/// rendering (screenshots, previews for the gallery).
private struct HomeWidgetOpaqueSurfaceKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    var homeWidgetOpaqueSurface: Bool {
        get { self[HomeWidgetOpaqueSurfaceKey.self] }
        set { self[HomeWidgetOpaqueSurfaceKey.self] = newValue }
    }
}

/// A resolved subtitle fragment for a non-default setting, e.g. "flotilla"
/// or "30d" — `HomeWidgetCard` joins whichever of these are non-nil with " · ".
struct HomeWidgetConfigSummary {
    var projectName: String?
    var timeWindowLabel: String?
    var agentLabel: String?

    var isEmpty: Bool { projectName == nil && timeWindowLabel == nil && agentLabel == nil }

    var text: String? {
        let parts = [projectName, timeWindowLabel, agentLabel].compactMap { $0 }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }
}

/// The chrome every widget renders inside: glass card, title, optional
/// count/subtitle, and — in edit mode — the remove badge, info badge and
/// resize handle. Content-agnostic; `HomeWidgetView` supplies what goes
/// inside.
struct HomeWidgetCard<Content: View>: View {
    let kind: HomeWidgetKind
    let size: HomeWidgetSize
    var count: Int?
    var configSummary: HomeWidgetConfigSummary = HomeWidgetConfigSummary()
    var showsHeader = true
    @ViewBuilder let content: Content

    var isEditing = false
    var onRemove: (() -> Void)?
    var onShowSettings: (() -> Void)?
    var onBeginResize: ((CGSize) -> Void)?
    var onCommitResize: (() -> Void)?

    @Environment(\.homeWidgetOpaqueSurface) private var opaque
    @State private var isHovering = false

    private var shape: RoundedRectangle {
        RoundedRectangle(cornerRadius: FlotillaRadius.modal + 4, style: .continuous)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: FlotillaSpacing.small + 2) {
            if showsHeader {
                header
            }
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .allowsHitTesting(!isEditing)
        }
        .padding(FlotillaSpacing.large - 2)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background {
            if opaque {
                shape.fill(FlotillaColors.surfaceElevated.opacity(0.92))
            } else {
                Color.clear.glassEffect(.regular, in: shape)
            }
        }
        .overlay {
            shape.strokeBorder(
                isEditing ? FlotillaColors.textPrimary.opacity(0.16) : FlotillaColors.textPrimary.opacity(0.08),
                style: isEditing ? StrokeStyle(lineWidth: 1.5, dash: [5, 4]) : StrokeStyle(lineWidth: FlotillaBorderWidth.thin)
            )
        }
        .clipShape(shape)
        .overlay(alignment: .topLeading) { if isEditing { removeBadge } }
        .overlay(alignment: .topTrailing) { if isEditing, onShowSettings != nil { infoBadge } }
        .overlay(alignment: .bottomTrailing) { if isEditing, onBeginResize != nil { resizeHandle } }
        .onHover { isHovering = $0 }
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
    }

    // MARK: Edit badges

    private var removeBadge: some View {
        Button(role: .destructive) { onRemove?() } label: {
            Image(systemName: "minus")
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: 18, height: 18)
                .background(FlotillaColors.statusCrashed, in: Circle())
                .overlay(Circle().strokeBorder(.white.opacity(0.6), lineWidth: 1))
        }
        .buttonStyle(.plain)
        .offset(x: -6, y: -6)
        .shadow(radius: 2, y: 1)
        .accessibilityLabel("Remove \(kind.title) widget")
        .accessibilityIdentifier(AXID.homeWidgetRemoveBadge.rawValue + kind.rawValue)
    }

    private var infoBadge: some View {
        Button { onShowSettings?() } label: {
            Image(systemName: "info.circle.fill")
                .font(.system(size: 15, weight: .regular))
                .foregroundStyle(FlotillaColors.textSecondary, FlotillaColors.surfaceElevated)
        }
        .buttonStyle(.plain)
        .offset(x: 6, y: -6)
        .accessibilityLabel("Edit \(kind.title) widget settings")
        .accessibilityIdentifier(AXID.homeWidgetInfoBadge.rawValue + kind.rawValue)
    }

    private var resizeHandle: some View {
        Image(systemName: "arrow.down.right.and.arrow.up.left")
            .font(.system(size: 9, weight: .bold))
            .foregroundStyle(FlotillaColors.textSecondary)
            .frame(width: 18, height: 18)
            .background(FlotillaColors.surfaceElevated, in: Circle())
            .overlay(Circle().strokeBorder(FlotillaColors.textPrimary.opacity(0.15), lineWidth: 1))
            .offset(x: 6, y: 6)
            .opacity(isHovering ? 1 : 0)
            .gesture(
                DragGesture(minimumDistance: 2, coordinateSpace: .global)
                    .onChanged { onBeginResize?($0.translation) }
                    .onEnded { _ in onCommitResize?() }
            )
            .accessibilityLabel("Resize \(kind.title) widget")
            .accessibilityIdentifier(AXID.homeWidgetResizeHandle.rawValue + kind.rawValue)
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

/// Shown when a widget's data is present but empty, e.g. nothing waiting or
/// nothing uncommitted — stays in place rather than collapsing, so the grid
/// never reflows out from under you.
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

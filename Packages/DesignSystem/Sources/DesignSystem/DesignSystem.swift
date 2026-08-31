import SwiftUI
import AppKit

// MARK: - Core Tokens
public enum FlotillaSpacing: Sendable {
    public static let xSmall: CGFloat = 4
    public static let small: CGFloat = 8
    public static let medium: CGFloat = 12
    public static let large: CGFloat = 16
    public static let xLarge: CGFloat = 24
    public static let xxLarge: CGFloat = 32
}

public enum FlotillaRadius {
    public static let control: CGFloat = 6
    public static let card: CGFloat = 10
    public static let panel: CGFloat = 14
    public static let modal: CGFloat = 16

    @available(*, deprecated, renamed: "control")
    public static let small: CGFloat = 6

    @available(*, deprecated, renamed: "card")
    public static let medium: CGFloat = 10

    @available(*, deprecated, renamed: "panel")
    public static let large: CGFloat = 14
}

@available(*, deprecated, renamed: "FlotillaRadius.control")
public let FlotillaRadiusSmall: CGFloat = 6

@available(*, deprecated, renamed: "FlotillaRadius.card")
public let FlotillaRadiusMedium: CGFloat = 10

@available(*, deprecated, renamed: "FlotillaRadius.panel")
public let FlotillaRadiusLarge: CGFloat = 14

// MARK: - Border Width
public enum FlotillaBorderWidth: Sendable {
    public static let hairline: CGFloat = 0.5
    public static let thin: CGFloat = 1
    public static let medium: CGFloat = 1.5
    public static let thick: CGFloat = 2
}

// MARK: - Icon Size
public enum FlotillaIconSize: Sendable {
    public static let xSmall: CGFloat = 10
    public static let small: CGFloat = 12
    public static let medium: CGFloat = 16
    public static let large: CGFloat = 20
    public static let xLarge: CGFloat = 24
    public static let xxLarge: CGFloat = 32
}

// MARK: - Control Height
public enum FlotillaControlHeight: Sendable {
    public static let xSmall: CGFloat = 20
    public static let small: CGFloat = 28
    public static let medium: CGFloat = 36
    public static let large: CGFloat = 44
    public static let xLarge: CGFloat = 56
}

// MARK: - Layout Widths
public enum FlotillaLayoutWidth: Sendable {
    // Measured, not guessed: a session row spends 54pt on the provider icon,
    // its spacing, and the row's own padding before any text starts. Past
    // that, the worst realistic case — status word "Needs Permission" (91pt)
    // + separator + a full branch name like "flotilla/worktree-cleanup"
    // (155pt) on the metadata line, or a long title like "Investigate flaky
    // terminal snapshot test" (229pt) + its timestamp (19pt) on the title
    // line — needs ~260-320pt of actual content width. `ideal` is
    // deliberately generous so a fresh launch makes the session sidebar
    // unmistakable; `min` still supports a compact user-resized layout, and
    // `max` leaves a useful detail column at the 1,280pt default window width.
    public static let sidebarMin: CGFloat = 260
    public static let sidebarIdeal: CGFloat = 600
    public static let sidebarMax: CGFloat = 720
    /// Only `inspectorMin` is live, in the skills ledger's docked detail pane.
    /// `inspectorIdeal`/`inspectorMax` were sized for a session inspector that
    /// was never built; they go rather than sit here describing a pane that
    /// does not exist. Reintroduce them with it.
    public static let inspectorMin: CGFloat = 280
    public static let contentMax: CGFloat = 920
    public static let windowMin: CGFloat = 1000
    public static let windowHeightMin: CGFloat = 640
}

// MARK: - State Opacity
public enum FlotillaStateOpacity: Sendable {
    public static let hover: CGFloat = 0.08
    public static let press: CGFloat = 0.12
    public static let selected: CGFloat = 0.16
    public static let disabled: CGFloat = 0.4
    public static let focus: CGFloat = 0.2
}

// MARK: - Color System
public struct FlotillaColors: Sendable {
    private static func dynamic(dark: NSColor, light: NSColor) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? dark : light
        })
    }

    // MARK: - Surfaces
    public static let canvas = dynamic(
        dark: NSColor(red: 10/255, green: 10/255, blue: 12/255, alpha: 1),
        light: NSColor(red: 250/255, green: 250/255, blue: 252/255, alpha: 1)
    )

    public static let sidebar = dynamic(
        dark: NSColor(red: 18/255, green: 18/255, blue: 22/255, alpha: 1),
        light: NSColor(red: 242/255, green: 242/255, blue: 247/255, alpha: 1)
    )

    public static let surface = dynamic(
        dark: NSColor(red: 22/255, green: 22/255, blue: 26/255, alpha: 1),
        light: NSColor(red: 255/255, green: 255/255, blue: 255/255, alpha: 1)
    )

    public static let surfaceElevated = dynamic(
        dark: NSColor(red: 30/255, green: 30/255, blue: 35/255, alpha: 1),
        light: NSColor(red: 245/255, green: 245/255, blue: 250/255, alpha: 1)
    )

    public static let terminalCanvas = dynamic(
        dark: NSColor(red: 10/255, green: 10/255, blue: 12/255, alpha: 1),
        light: NSColor(red: 28/255, green: 28/255, blue: 30/255, alpha: 1)
    )

    // MARK: - Content
    public static let textPrimary = dynamic(
        dark: NSColor.white,
        light: NSColor.black
    )

    public static let textSecondary = dynamic(
        dark: NSColor.white.withAlphaComponent(0.72),
        light: NSColor.black.withAlphaComponent(0.68)
    )

    public static let textTertiary = dynamic(
        dark: NSColor.white.withAlphaComponent(0.44),
        light: NSColor.black.withAlphaComponent(0.4)
    )

    // MARK: - Lines
    public static let separator = dynamic(
        dark: NSColor(red: 50/255, green: 50/255, blue: 58/255, alpha: 1),
        light: NSColor(red: 200/255, green: 200/255, blue: 205/255, alpha: 1)
    )

    public static let separatorStrong = dynamic(
        dark: NSColor(red: 70/255, green: 70/255, blue: 80/255, alpha: 1),
        light: NSColor(red: 170/255, green: 170/255, blue: 180/255, alpha: 1)
    )

    // MARK: - Accent
    public static let accent = dynamic(
        dark: NSColor(red: 0.96, green: 0.36, blue: 0.16, alpha: 1),
        light: NSColor(red: 0.85, green: 0.3, blue: 0.12, alpha: 1)
    )

    public static let accentContent = Color.white

    // MARK: - Status (one per SessionStatus)
    public static let statusWorking = dynamic(
        dark: NSColor(red: 0.19, green: 0.78, blue: 0.64, alpha: 1),
        light: NSColor(red: 0.14, green: 0.62, blue: 0.5, alpha: 1)
    )

    public static let statusIdle = dynamic(
        dark: NSColor.white.withAlphaComponent(0.44),
        light: NSColor.black.withAlphaComponent(0.4)
    )

    public static let statusWaitingForInput = dynamic(
        dark: NSColor(red: 1.0, green: 0.58, blue: 0.0, alpha: 1),
        light: NSColor(red: 0.85, green: 0.45, blue: 0.0, alpha: 1)
    )

    public static let statusReady = dynamic(
        dark: NSColor(red: 0.26, green: 0.72, blue: 0.92, alpha: 1),
        light: NSColor(red: 0.0, green: 0.5, blue: 0.8, alpha: 1)
    )

    public static let statusFinished = dynamic(
        dark: NSColor(red: 0.0, green: 0.48, blue: 1.0, alpha: 1),
        light: NSColor(red: 0.0, green: 0.38, blue: 0.85, alpha: 1)
    )

    public static let statusCrashed = dynamic(
        dark: NSColor(red: 1.0, green: 0.27, blue: 0.23, alpha: 1),
        light: NSColor(red: 0.85, green: 0.18, blue: 0.14, alpha: 1)
    )

    // MARK: - Feedback
    public static let danger = dynamic(
        dark: NSColor(red: 1.0, green: 0.27, blue: 0.23, alpha: 1),
        light: NSColor(red: 0.85, green: 0.18, blue: 0.14, alpha: 1)
    )

    public static let dangerSurface = dynamic(
        dark: NSColor(red: 1.0, green: 0.27, blue: 0.23, alpha: 1).withAlphaComponent(0.12),
        light: NSColor(red: 0.85, green: 0.18, blue: 0.14, alpha: 1).withAlphaComponent(0.1)
    )

    public static let warning = dynamic(
        dark: NSColor(red: 1.0, green: 0.8, blue: 0.0, alpha: 1),
        light: NSColor(red: 0.8, green: 0.6, blue: 0.0, alpha: 1)
    )

    public static let warningSurface = dynamic(
        dark: NSColor(red: 1.0, green: 0.8, blue: 0.0, alpha: 1).withAlphaComponent(0.12),
        light: NSColor(red: 0.8, green: 0.6, blue: 0.0, alpha: 1).withAlphaComponent(0.1)
    )

    public static let success = dynamic(
        dark: NSColor(red: 0.19, green: 0.78, blue: 0.64, alpha: 1),
        light: NSColor(red: 0.14, green: 0.62, blue: 0.5, alpha: 1)
    )

    public static let successSurface = dynamic(
        dark: NSColor(red: 0.19, green: 0.78, blue: 0.64, alpha: 1).withAlphaComponent(0.12),
        light: NSColor(red: 0.14, green: 0.62, blue: 0.5, alpha: 1).withAlphaComponent(0.1)
    )

    // MARK: - Diff (colorblind-safe)
    public static let diffAdded = dynamic(
        dark: NSColor(red: 0.2, green: 0.75, blue: 0.35, alpha: 1),
        light: NSColor(red: 0.15, green: 0.6, blue: 0.25, alpha: 1)
    )

    public static let diffAddedSurface = dynamic(
        dark: NSColor(red: 0.2, green: 0.75, blue: 0.35, alpha: 1).withAlphaComponent(0.12),
        light: NSColor(red: 0.15, green: 0.6, blue: 0.25, alpha: 1).withAlphaComponent(0.1)
    )

    public static let diffRemoved = dynamic(
        dark: NSColor(red: 1.0, green: 0.3, blue: 0.3, alpha: 1),
        light: NSColor(red: 0.85, green: 0.2, blue: 0.2, alpha: 1)
    )

    public static let diffRemovedSurface = dynamic(
        dark: NSColor(red: 1.0, green: 0.3, blue: 0.3, alpha: 1).withAlphaComponent(0.12),
        light: NSColor(red: 0.85, green: 0.2, blue: 0.2, alpha: 1).withAlphaComponent(0.1)
    )

    @available(*, deprecated, message: "Use static properties directly, e.g. FlotillaColors.canvas")
    public init(colorScheme: ColorScheme = .dark) {}
}

// MARK: - Shared Components
public struct FlotillaPanel: ViewModifier {
    public init() {}

    public func body(content: Content) -> some View {
        content
            .background(FlotillaColors.surface)
            .clipShape(RoundedRectangle(cornerRadius: FlotillaRadius.panel, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: FlotillaRadius.panel, style: .continuous)
                    .strokeBorder(FlotillaColors.separator)
            }
    }
}

public extension View {
    func flotillaPanel() -> some View {
        modifier(FlotillaPanel())
    }
}

// MARK: - View Extensions for Spacing
public extension View {
    func flotillaPadding(_ edges: Edge.Set = .all, _ length: CGFloat = FlotillaSpacing.medium) -> some View {
        padding(edges, length)
    }

    func flotillaPaddingXSmall() -> some View { padding(FlotillaSpacing.xSmall) }
    func flotillaPaddingSmall() -> some View { padding(FlotillaSpacing.small) }
    func flotillaPaddingMedium() -> some View { padding(FlotillaSpacing.medium) }
    func flotillaPaddingLarge() -> some View { padding(FlotillaSpacing.large) }
    func flotillaPaddingXLarge() -> some View { padding(FlotillaSpacing.xLarge) }
    func flotillaPaddingXXLarge() -> some View { padding(FlotillaSpacing.xxLarge) }

    func flotillaPaddingHorizontal(_ length: CGFloat = FlotillaSpacing.medium) -> some View {
        padding(.horizontal, length)
    }

    func flotillaPaddingVertical(_ length: CGFloat = FlotillaSpacing.medium) -> some View {
        padding(.vertical, length)
    }
}

// MARK: - View Extensions for Border
public extension View {
    func flotillaBorder(_ color: Color = FlotillaColors.separator, width: CGFloat = FlotillaBorderWidth.thin) -> some View {
        overlay(
            RoundedRectangle(cornerRadius: FlotillaRadius.control, style: .continuous)
                .strokeBorder(color, lineWidth: width)
        )
    }

    func flotillaBorderHairline(_ color: Color = FlotillaColors.separator) -> some View {
        flotillaBorder(color, width: FlotillaBorderWidth.hairline)
    }

    func flotillaBorderThin(_ color: Color = FlotillaColors.separator) -> some View {
        flotillaBorder(color, width: FlotillaBorderWidth.thin)
    }

    func flotillaBorderMedium(_ color: Color = FlotillaColors.separator) -> some View {
        flotillaBorder(color, width: FlotillaBorderWidth.medium)
    }
}

// MARK: - View Extensions for State Opacity
public extension View {
    func flotillaHoverOpacity() -> some View { opacity(FlotillaStateOpacity.hover) }
    func flotillaPressOpacity() -> some View { opacity(FlotillaStateOpacity.press) }
    func flotillaSelectedOpacity() -> some View { opacity(FlotillaStateOpacity.selected) }
    func flotillaDisabledOpacity() -> some View { opacity(FlotillaStateOpacity.disabled) }
    func flotillaFocusOpacity() -> some View { opacity(FlotillaStateOpacity.focus) }
}

// Types are directly available in the module — no re-exports needed.
// Import DesignSystem to access: FlotillaTypography, FlotillaElevation, FlotillaMotion,
// StatusBadge, StatusBadgeSize, FlotillaBanner, FlotillaBannerStyle

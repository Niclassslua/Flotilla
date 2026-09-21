import SwiftUI
import SessionKit
#if os(macOS)
import AppKit
public typealias PlatformColor = NSColor
#else
import UIKit
public typealias PlatformColor = UIColor
#endif

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
    // line — needs ~260-320pt of actual content width. `ideal` sits just past
    // that worst case rather than well beyond it: the sidebar is a list to
    // pick from, and the detail column is where the work happens, so a fresh
    // launch should not hand it half the window. `min` still supports a
    // compact user-resized layout, and `max` leaves room to widen it for long
    // branch names without swallowing the detail column.
    public static let sidebarMin: CGFloat = 260
    public static let sidebarIdeal: CGFloat = 360
    public static let sidebarMax: CGFloat = 560
    /// Shared by docked detail surfaces. The Git sidebar needs enough room
    /// for a filename, path, and diff stat while remaining subordinate to the
    /// live terminal it supplements.
    public static let inspectorMin: CGFloat = 280
    public static let inspectorIdeal: CGFloat = 360
    public static let inspectorMax: CGFloat = 480
    public static let contentMax: CGFloat = 920
    /// The floor the detail column needs to lay out its own content — Home's
    /// project grid alone wants one 340pt card plus its horizontal padding.
    /// Without a floor, dragging the sidebar toward `sidebarMax` on a
    /// `windowMin`-wide window left the detail column narrower than its
    /// content could shrink to, and the content overflowed the split
    /// boundary on both sides instead of clipping to it.
    public static let detailMin: CGFloat = 480
    /// `windowMin` minus `sidebarIdeal` — what the detail column actually
    /// gets on a freshly launched, minimum-size window.
    public static let detailIdeal: CGFloat = 680
    // Guarantees the detail column can always reach `detailMin`, even with
    // the sidebar dragged all the way to `sidebarMax`.
    public static let windowMin: CGFloat = sidebarMax + detailMin
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
    private static func dynamic(dark: PlatformColor, light: PlatformColor) -> Color {
        #if os(macOS)
        Color(nsColor: NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? dark : light
        })
        #else
        Color(uiColor: UIColor { traits in
            traits.userInterfaceStyle == .dark ? dark : light
        })
        #endif
    }

    // MARK: - Surfaces
    public static let canvas = dynamic(
        dark: PlatformColor(red: 10/255, green: 10/255, blue: 12/255, alpha: 1),
        light: PlatformColor(red: 250/255, green: 250/255, blue: 252/255, alpha: 1)
    )

    public static let sidebar = dynamic(
        dark: PlatformColor(red: 18/255, green: 18/255, blue: 22/255, alpha: 1),
        light: PlatformColor(red: 242/255, green: 242/255, blue: 247/255, alpha: 1)
    )

    public static let surface = dynamic(
        dark: PlatformColor(red: 22/255, green: 22/255, blue: 26/255, alpha: 1),
        light: PlatformColor(red: 255/255, green: 255/255, blue: 255/255, alpha: 1)
    )

    public static let surfaceElevated = dynamic(
        dark: PlatformColor(red: 30/255, green: 30/255, blue: 35/255, alpha: 1),
        light: PlatformColor(red: 245/255, green: 245/255, blue: 250/255, alpha: 1)
    )

    public static let terminalCanvas = dynamic(
        dark: PlatformColor(red: 10/255, green: 10/255, blue: 12/255, alpha: 1),
        light: PlatformColor(red: 28/255, green: 28/255, blue: 30/255, alpha: 1)
    )

    // MARK: - Content
    public static let textPrimary = dynamic(
        dark: PlatformColor.white,
        light: PlatformColor.black
    )

    public static let textSecondary = dynamic(
        dark: PlatformColor.white.withAlphaComponent(0.72),
        light: PlatformColor.black.withAlphaComponent(0.68)
    )

    public static let textTertiary = dynamic(
        dark: PlatformColor.white.withAlphaComponent(0.44),
        light: PlatformColor.black.withAlphaComponent(0.4)
    )

    // MARK: - Lines
    public static let separator = dynamic(
        dark: PlatformColor(red: 50/255, green: 50/255, blue: 58/255, alpha: 1),
        light: PlatformColor(red: 200/255, green: 200/255, blue: 205/255, alpha: 1)
    )

    public static let separatorStrong = dynamic(
        dark: PlatformColor(red: 70/255, green: 70/255, blue: 80/255, alpha: 1),
        light: PlatformColor(red: 170/255, green: 170/255, blue: 180/255, alpha: 1)
    )

    // MARK: - Accent
    public static var accent: Color {
        FlotillaAccent.currentColor
    }

    public static var originalAccent: Color {
        FlotillaAccent.originalColor
    }

    public static let accentContent = Color.white

    // MARK: - Status (one per SessionStatus)
    public static let statusWorking = dynamic(
        dark: PlatformColor(red: 0.19, green: 0.78, blue: 0.64, alpha: 1),
        light: PlatformColor(red: 0.14, green: 0.62, blue: 0.5, alpha: 1)
    )

    public static let statusIdle = dynamic(
        dark: PlatformColor.white.withAlphaComponent(0.44),
        light: PlatformColor.black.withAlphaComponent(0.4)
    )

    public static let statusWaitingForInput = dynamic(
        dark: PlatformColor(red: 1.0, green: 0.58, blue: 0.0, alpha: 1),
        light: PlatformColor(red: 0.85, green: 0.45, blue: 0.0, alpha: 1)
    )

    public static let statusReady = dynamic(
        dark: PlatformColor(red: 0.26, green: 0.72, blue: 0.92, alpha: 1),
        light: PlatformColor(red: 0.0, green: 0.5, blue: 0.8, alpha: 1)
    )

    public static let statusFinished = dynamic(
        dark: PlatformColor(red: 0.0, green: 0.48, blue: 1.0, alpha: 1),
        light: PlatformColor(red: 0.0, green: 0.38, blue: 0.85, alpha: 1)
    )

    public static let statusCrashed = dynamic(
        dark: PlatformColor(red: 1.0, green: 0.27, blue: 0.23, alpha: 1),
        light: PlatformColor(red: 0.85, green: 0.18, blue: 0.14, alpha: 1)
    )

    // MARK: - Feedback
    public static let danger = dynamic(
        dark: PlatformColor(red: 1.0, green: 0.27, blue: 0.23, alpha: 1),
        light: PlatformColor(red: 0.85, green: 0.18, blue: 0.14, alpha: 1)
    )

    public static let dangerSurface = dynamic(
        dark: PlatformColor(red: 1.0, green: 0.27, blue: 0.23, alpha: 1).withAlphaComponent(0.12),
        light: PlatformColor(red: 0.85, green: 0.18, blue: 0.14, alpha: 1).withAlphaComponent(0.1)
    )

    public static let warning = dynamic(
        dark: PlatformColor(red: 1.0, green: 0.8, blue: 0.0, alpha: 1),
        light: PlatformColor(red: 0.8, green: 0.6, blue: 0.0, alpha: 1)
    )

    public static let warningSurface = dynamic(
        dark: PlatformColor(red: 1.0, green: 0.8, blue: 0.0, alpha: 1).withAlphaComponent(0.12),
        light: PlatformColor(red: 0.8, green: 0.6, blue: 0.0, alpha: 1).withAlphaComponent(0.1)
    )

    public static let success = dynamic(
        dark: PlatformColor(red: 0.19, green: 0.78, blue: 0.64, alpha: 1),
        light: PlatformColor(red: 0.14, green: 0.62, blue: 0.5, alpha: 1)
    )

    public static let successSurface = dynamic(
        dark: PlatformColor(red: 0.19, green: 0.78, blue: 0.64, alpha: 1).withAlphaComponent(0.12),
        light: PlatformColor(red: 0.14, green: 0.62, blue: 0.5, alpha: 1).withAlphaComponent(0.1)
    )

    // MARK: - Diff (colorblind-safe)
    public static let diffAdded = dynamic(
        dark: PlatformColor(red: 0.2, green: 0.75, blue: 0.35, alpha: 1),
        light: PlatformColor(red: 0.15, green: 0.6, blue: 0.25, alpha: 1)
    )

    public static let diffAddedSurface = dynamic(
        dark: PlatformColor(red: 0.2, green: 0.75, blue: 0.35, alpha: 1).withAlphaComponent(0.12),
        light: PlatformColor(red: 0.15, green: 0.6, blue: 0.25, alpha: 1).withAlphaComponent(0.1)
    )

    public static let diffRemoved = dynamic(
        dark: PlatformColor(red: 1.0, green: 0.3, blue: 0.3, alpha: 1),
        light: PlatformColor(red: 0.85, green: 0.2, blue: 0.2, alpha: 1)
    )

    public static let diffRemovedSurface = dynamic(
        dark: PlatformColor(red: 1.0, green: 0.3, blue: 0.3, alpha: 1).withAlphaComponent(0.12),
        light: PlatformColor(red: 0.85, green: 0.2, blue: 0.2, alpha: 1).withAlphaComponent(0.1)
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

// MARK: - AgentEffort Tint
public extension AgentEffort {
    /// Cool-to-hot ramp: slate → steel → cyan → amber → orange → red →
    /// magenta. Used as a foreground tint throughout, never as a fill behind
    /// text, so every step only has to read against the panel background.
    var tint: Color {
        switch self {
        case .minimal: Color(red: 0.42, green: 0.47, blue: 0.53)
        case .low: Color(red: 0.30, green: 0.55, blue: 0.68)
        case .medium: FlotillaColors.statusReady
        case .high: FlotillaColors.warning
        case .xhigh: FlotillaColors.accent
        case .max: FlotillaColors.danger
        case .ultra: Color(red: 0.80, green: 0.30, blue: 0.72)
        }
    }
}

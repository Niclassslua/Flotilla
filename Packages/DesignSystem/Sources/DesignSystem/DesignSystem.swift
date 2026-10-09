import SwiftUI
import SessionKit
#if os(macOS)
import AppKit
public typealias PlatformColor = NSColor
#else
import UIKit
public typealias PlatformColor = UIColor
#endif

public extension EnvironmentValues {
    /// Whether the workspace uses macOS 26's translucent Liquid Glass chrome.
    /// The app owns the persisted preference; the design system only consumes it.
    /// Defaults off — Liquid Glass is opt-in / experimental.
    @Entry var flotillaLiquidGlassEnabled = false
}

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
}

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
    /// Project overview's trailing context rail (working tree / worktrees /
    /// this week). Fixed width inside the detail column — not collapsible —
    /// so it raises the detail floor whenever a project is open beside the
    /// session sidebar.
    public static let projectContextWidth: CGFloat = 344
    /// The width below which the detail column cannot actually lay out,
    /// measured rather than estimated: 560pt of it is window chrome the
    /// column keeps even with completely empty content, and Home's header
    /// and project grid add the rest (~750). The project overview then
    /// parks a fixed `projectContextWidth` rail beside the feed, so the
    /// real floor is Home's measurement plus that rail.
    ///
    /// This has to be the *real* floor, because `NavigationSplitView` holds
    /// the sidebar at whatever width it has been dragged to and shrinks the
    /// detail column to make room (both `.balanced` and `.prominentDetail`
    /// behave this way). Once the detail hits its floor the split view stops
    /// shrinking and slides its whole content leading-ward instead, which
    /// hangs the sidebar off the window's leading edge and clips its rows.
    /// Omitting the project context rail let that clipping return whenever
    /// a project was open with both sidebars visible.
    public static let detailMin: CGFloat = 750 + projectContextWidth
    /// What the detail column gets beside a sidebar at `sidebarIdeal` on a
    /// freshly launched, minimum-size window (`windowMin - sidebarIdeal`).
    public static let detailIdeal: CGFloat = sidebarMax + detailMin - sidebarIdeal
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
}

// MARK: - Glass Tint Tokens
/// Named opacities for `.flotillaLiquidSurface` / inspector chrome so Features
/// do not invent magic numbers per call site.
public enum FlotillaGlassTint: Sendable {
    /// Detail column / primary workspace canvas.
    public static let detail: CGFloat = 0.24
    /// Navigator / sidebar column.
    public static let sidebar: CGFloat = 0.42
    /// Terminal tile and session card surfaces.
    public static let terminal: CGFloat = 0.48
    /// Elevated cards (home, project, floating overlays).
    public static let elevated: CGFloat = 0.34
    /// Docked inspectors (git / diff / screenshots).
    public static let inspector: CGFloat = 0.55
}

// MARK: - Shared Components
public struct FlotillaPanel: ViewModifier {
    @Environment(\.flotillaLiquidGlassEnabled) private var liquidGlassEnabled
    public init() {}

    public func body(content: Content) -> some View {
        content
            .background {
                if liquidGlassEnabled, #available(macOS 26.0, iOS 26.0, *) {
                    Color.clear
                        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: FlotillaRadius.panel, style: .continuous))
                } else {
                    FlotillaColors.surface
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: FlotillaRadius.panel, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: FlotillaRadius.panel, style: .continuous)
                    .strokeBorder(FlotillaColors.separator)
            }
    }
}

/// Elevated floating card (palette, launcher, sheets). Glass when enabled;
/// opaque `surface` with hairline stroke when not.
public struct FlotillaFloatingCard: ViewModifier {
    @Environment(\.flotillaLiquidGlassEnabled) private var liquidGlassEnabled
    let cornerRadius: CGFloat
    let glassTintOpacity: CGFloat

    public init(
        cornerRadius: CGFloat = FlotillaRadius.modal,
        glassTintOpacity: CGFloat = FlotillaGlassTint.elevated
    ) {
        self.cornerRadius = cornerRadius
        self.glassTintOpacity = glassTintOpacity
    }

    public func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        content
            .background {
                if liquidGlassEnabled, #available(macOS 26.0, iOS 26.0, *) {
                    Color.clear
                        .glassEffect(
                            .regular.tint(FlotillaColors.canvas.opacity(glassTintOpacity)),
                            in: shape
                        )
                } else {
                    FlotillaColors.surface
                }
            }
            .clipShape(shape)
            .overlay {
                shape.strokeBorder(FlotillaColors.separator, lineWidth: FlotillaBorderWidth.hairline)
            }
    }
}

/// Preference-gated glass chrome for capsules (action clusters, agent chips).
/// Pass `fallback: nil` when glass-off should leave the view unbacked (e.g. a
/// focus-bar action cluster that is only chrome in glass mode).
public struct FlotillaChromeCapsule: ViewModifier {
    @Environment(\.flotillaLiquidGlassEnabled) private var liquidGlassEnabled
    let tint: Color?
    let interactive: Bool
    let fallback: Color?

    public init(
        tint: Color? = nil,
        interactive: Bool = false,
        fallback: Color? = FlotillaColors.surfaceElevated
    ) {
        self.tint = tint
        self.interactive = interactive
        self.fallback = fallback
    }

    public func body(content: Content) -> some View {
        content
            .background {
                if liquidGlassEnabled, #available(macOS 26.0, iOS 26.0, *) {
                    Color.clear
                        .glassEffect(glassStyle, in: .capsule)
                } else if let fallback {
                    Capsule().fill(fallback)
                }
            }
    }

    @available(macOS 26.0, iOS 26.0, *)
    private var glassStyle: Glass {
        var style: Glass = .regular
        if let tint {
            style = style.tint(tint)
        }
        if interactive {
            style = style.interactive()
        }
        return style
    }
}

/// Preference-gated glass chrome for circular controls (FABs).
public struct FlotillaChromeCircle: ViewModifier {
    @Environment(\.flotillaLiquidGlassEnabled) private var liquidGlassEnabled
    let interactive: Bool
    let fallback: Color

    public init(
        interactive: Bool = true,
        fallback: Color = FlotillaColors.surfaceElevated
    ) {
        self.interactive = interactive
        self.fallback = fallback
    }

    public func body(content: Content) -> some View {
        content
            .background {
                if liquidGlassEnabled, #available(macOS 26.0, iOS 26.0, *) {
                    Color.clear
                        .glassEffect(
                            interactive ? .regular.interactive() : .regular,
                            in: .circle
                        )
                } else {
                    Circle().fill(fallback)
                }
            }
    }
}

public extension View {
    func flotillaPanel() -> some View {
        modifier(FlotillaPanel())
    }

    /// Elevated floating overlay card (command palette, launcher, sheets).
    func flotillaFloatingCard(
        cornerRadius: CGFloat = FlotillaRadius.modal,
        glassTintOpacity: CGFloat = FlotillaGlassTint.elevated
    ) -> some View {
        modifier(FlotillaFloatingCard(cornerRadius: cornerRadius, glassTintOpacity: glassTintOpacity))
    }

    /// Docked inspector column (git sidebar, diff panel, screenshot panel).
    func flotillaInspectorSurface(
        ignoresSafeAreaEdges: Edge.Set = []
    ) -> some View {
        flotillaLiquidSurface(
            FlotillaColors.sidebar,
            glassTintOpacity: FlotillaGlassTint.inspector,
            ignoresSafeAreaEdges: ignoresSafeAreaEdges
        )
    }

    /// Capsule chrome for bar chips and action clusters.
    /// Pass `fallback: nil` when glass-off should leave the view unbacked.
    func flotillaChromeCapsule(
        tint: Color? = nil,
        interactive: Bool = false,
        fallback: Color? = FlotillaColors.surfaceElevated
    ) -> some View {
        modifier(FlotillaChromeCapsule(tint: tint, interactive: interactive, fallback: fallback))
    }

    /// Circle chrome for FABs and round controls.
    func flotillaChromeCircle(
        interactive: Bool = true,
        fallback: Color = FlotillaColors.surfaceElevated
    ) -> some View {
        modifier(FlotillaChromeCircle(interactive: interactive, fallback: fallback))
    }

    /// A full-height workspace surface: refractive in Liquid Glass mode and
    /// the original opaque surface when the user disables that appearance.
    ///
    /// `ignoresSafeAreaEdges` mirrors `background(_:ignoresSafeAreaEdges:)`:
    /// a column passes `.top` so its glass continues under a window toolbar
    /// whose own background is hidden, instead of stopping at its bottom edge.
    func flotillaLiquidSurface(
        _ fallback: Color,
        cornerRadius: CGFloat = 0,
        glassTintOpacity: CGFloat = FlotillaGlassTint.elevated,
        stableTintOpacity: CGFloat = 0,
        ignoresSafeAreaEdges: Edge.Set = []
    ) -> some View {
        modifier(
            FlotillaLiquidSurface(
                fallback: fallback,
                cornerRadius: cornerRadius,
                glassTintOpacity: glassTintOpacity,
                stableTintOpacity: stableTintOpacity,
                ignoresSafeAreaEdges: ignoresSafeAreaEdges
            )
        )
    }
}

public struct FlotillaLiquidSurface: ViewModifier {
    @Environment(\.flotillaLiquidGlassEnabled) private var liquidGlassEnabled
    let fallback: Color
    let cornerRadius: CGFloat
    let glassTintOpacity: CGFloat
    let stableTintOpacity: CGFloat
    let ignoresSafeAreaEdges: Edge.Set

    public func body(content: Content) -> some View {
        content.background {
            Group {
                if liquidGlassEnabled, #available(macOS 26.0, iOS 26.0, *) {
                    Color.clear
                        .glassEffect(
                            .regular.tint(FlotillaColors.canvas.opacity(glassTintOpacity)),
                            in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        )
                        .overlay {
                            if stableTintOpacity > 0 {
                                fallback.opacity(stableTintOpacity)
                                    .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
                            }
                        }
                } else {
                    fallback
                }
            }
            .ignoresSafeArea(edges: ignoresSafeAreaEdges)
        }
    }
}

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

import SwiftUI

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

// MARK: - Color System
public struct FlotillaColors: Sendable {
    public let colorScheme: ColorScheme

    public init(colorScheme: ColorScheme = .dark) {
        self.colorScheme = colorScheme
    }

    // MARK: - Surfaces
    public var canvas: Color {
        colorScheme == .dark
            ? Color(red: 10/255, green: 10/255, blue: 12/255)
            : Color(red: 250/255, green: 250/255, blue: 252/255)
    }

    public var sidebar: Color {
        colorScheme == .dark
            ? Color(red: 18/255, green: 18/255, blue: 22/255)
            : Color(red: 242/255, green: 242/255, blue: 247/255)
    }

    public var surface: Color {
        colorScheme == .dark
            ? Color(red: 22/255, green: 22/255, blue: 26/255)
            : Color(red: 255/255, green: 255/255, blue: 255/255)
    }

    public var surfaceElevated: Color {
        colorScheme == .dark
            ? Color(red: 30/255, green: 30/255, blue: 35/255)
            : Color(red: 245/255, green: 245/255, blue: 250/255)
    }

    public var terminalCanvas: Color {
        colorScheme == .dark
            ? Color(red: 10/255, green: 10/255, blue: 12/255)
            : Color(red: 28/255, green: 28/255, blue: 30/255)
    }

    // MARK: - Content
    public var textPrimary: Color {
        colorScheme == .dark ? .white : .black
    }

    public var textSecondary: Color {
        colorScheme == .dark
            ? Color.white.opacity(0.72)
            : Color.black.opacity(0.68)
    }

    public var textTertiary: Color {
        colorScheme == .dark
            ? Color.white.opacity(0.44)
            : Color.black.opacity(0.4)
    }

    // MARK: - Lines
    public var separator: Color {
        colorScheme == .dark
            ? Color(red: 50/255, green: 50/255, blue: 58/255)
            : Color(red: 200/255, green: 200/255, blue: 205/255)
    }

    public var separatorStrong: Color {
        colorScheme == .dark
            ? Color(red: 70/255, green: 70/255, blue: 80/255)
            : Color(red: 170/255, green: 170/255, blue: 180/255)
    }

    // MARK: - Accent
    public var accent: Color {
        colorScheme == .dark
            ? Color(red: 0.96, green: 0.36, blue: 0.16)
            : Color(red: 0.85, green: 0.3, blue: 0.12)
    }

    public var accentContent: Color {
        .white
    }

    // MARK: - Status (one per SessionStatus)
    public var statusWorking: Color {
        colorScheme == .dark
            ? Color(red: 0.19, green: 0.78, blue: 0.64)
            : Color(red: 0.14, green: 0.62, blue: 0.5)
    }

    public var statusIdle: Color {
        colorScheme == .dark
            ? Color.white.opacity(0.44)
            : Color.black.opacity(0.4)
    }

    public var statusWaitingForInput: Color {
        colorScheme == .dark
            ? Color(red: 1.0, green: 0.58, blue: 0.0)
            : Color(red: 0.85, green: 0.45, blue: 0.0)
    }

    public var statusReady: Color {
        colorScheme == .dark
            ? Color(red: 0.26, green: 0.72, blue: 0.92)
            : Color(red: 0.0, green: 0.5, blue: 0.8)
    }

    public var statusFinished: Color {
        colorScheme == .dark
            ? Color(red: 0.0, green: 0.48, blue: 1.0)
            : Color(red: 0.0, green: 0.38, blue: 0.85)
    }

    public var statusCrashed: Color {
        colorScheme == .dark
            ? Color(red: 1.0, green: 0.27, blue: 0.23)
            : Color(red: 0.85, green: 0.18, blue: 0.14)
    }

    // MARK: - Feedback
    public var danger: Color {
        colorScheme == .dark
            ? Color(red: 1.0, green: 0.27, blue: 0.23)
            : Color(red: 0.85, green: 0.18, blue: 0.14)
    }

    public var dangerSurface: Color {
        colorScheme == .dark
            ? Color(red: 1.0, green: 0.27, blue: 0.23).opacity(0.12)
            : Color(red: 0.85, green: 0.18, blue: 0.14).opacity(0.1)
    }

    public var warning: Color {
        colorScheme == .dark
            ? Color(red: 1.0, green: 0.8, blue: 0.0)
            : Color(red: 0.8, green: 0.6, blue: 0.0)
    }

    public var warningSurface: Color {
        colorScheme == .dark
            ? Color(red: 1.0, green: 0.8, blue: 0.0).opacity(0.12)
            : Color(red: 0.8, green: 0.6, blue: 0.0).opacity(0.1)
    }

    public var success: Color {
        colorScheme == .dark
            ? Color(red: 0.19, green: 0.78, blue: 0.64)
            : Color(red: 0.14, green: 0.62, blue: 0.5)
    }

    public var successSurface: Color {
        colorScheme == .dark
            ? Color(red: 0.19, green: 0.78, blue: 0.64).opacity(0.12)
            : Color(red: 0.14, green: 0.62, blue: 0.5).opacity(0.1)
    }

    // MARK: - Diff (colorblind-safe)
    public var diffAdded: Color {
        colorScheme == .dark
            ? Color(red: 0.2, green: 0.75, blue: 0.35)
            : Color(red: 0.15, green: 0.6, blue: 0.25)
    }

    public var diffAddedSurface: Color {
        colorScheme == .dark
            ? Color(red: 0.2, green: 0.75, blue: 0.35).opacity(0.12)
            : Color(red: 0.15, green: 0.6, blue: 0.25).opacity(0.1)
    }

    public var diffRemoved: Color {
        colorScheme == .dark
            ? Color(red: 1.0, green: 0.3, blue: 0.3)
            : Color(red: 0.85, green: 0.2, blue: 0.2)
    }

    public var diffRemovedSurface: Color {
        colorScheme == .dark
            ? Color(red: 1.0, green: 0.3, blue: 0.3).opacity(0.12)
            : Color(red: 0.85, green: 0.2, blue: 0.2).opacity(0.1)
    }
}

// Dynamic environment value that resolves colors based on current colorScheme
private struct FlotillaColorsKey: EnvironmentKey {
    static var defaultValue: FlotillaColors {
        FlotillaColors(colorScheme: .dark)
    }
}

public extension EnvironmentValues {
    var flotillaColors: FlotillaColors {
        get {
            // Resolve dynamically based on current colorScheme
            FlotillaColors(colorScheme: self.colorScheme)
        }
        set {
            // Not used - colors are resolved dynamically
        }
    }
}

public extension View {
    func flotillaColors(_ colors: FlotillaColors) -> some View {
        environment(\.flotillaColors, colors)
    }
}

// MARK: - Deprecated FlotillaPalette aliases (source-compatible)
@available(*, deprecated, message: "Use EnvironmentValues.flotillaColors.accent")
public var FlotillaPaletteOcean: Color { Color(red: 0.96, green: 0.36, blue: 0.16) }

@available(*, deprecated, message: "Use EnvironmentValues.flotillaColors.statusWorking")
public var FlotillaPaletteSignal: Color { Color(red: 0.19, green: 0.78, blue: 0.64) }

@available(*, deprecated, message: "Use EnvironmentValues.flotillaColors.statusReady")
public var FlotillaPaletteCyan: Color { Color(red: 0.26, green: 0.72, blue: 0.92) }

@available(*, deprecated, message: "Use EnvironmentValues.flotillaColors.canvas")
public var FlotillaPaletteCanvas: Color { Color(red: 10/255, green: 10/255, blue: 12/255) }

@available(*, deprecated, message: "Use EnvironmentValues.flotillaColors.sidebar")
public var FlotillaPaletteSidebar: Color { Color(red: 18/255, green: 18/255, blue: 22/255) }

@available(*, deprecated, message: "Use EnvironmentValues.flotillaColors.surface")
public var FlotillaPalettePanel: Color { Color(red: 22/255, green: 22/255, blue: 26/255) }

@available(*, deprecated, message: "Use EnvironmentValues.flotillaColors.surfaceElevated")
public var FlotillaPaletteElevated: Color { Color(red: 30/255, green: 30/255, blue: 35/255) }

@available(*, deprecated, message: "Use EnvironmentValues.flotillaColors.terminalCanvas")
public var FlotillaPaletteTerminal: Color { Color(red: 10/255, green: 10/255, blue: 12/255) }

@available(*, deprecated, message: "Use EnvironmentValues.flotillaColors.separator")
public var FlotillaPaletteSubtleStroke: Color { Color(red: 50/255, green: 50/255, blue: 58/255) }

@available(*, deprecated, message: "Use EnvironmentValues.flotillaColors.textTertiary")
public var FlotillaPaletteMutedText: Color { Color.white.opacity(0.52) }

public enum FlotillaPalette {
    @available(*, deprecated, message: "Use EnvironmentValues.flotillaColors.accent")
    public static let ocean = FlotillaPaletteOcean

    @available(*, deprecated, message: "Use EnvironmentValues.flotillaColors.statusWorking")
    public static let signal = FlotillaPaletteSignal

    @available(*, deprecated, message: "Use EnvironmentValues.flotillaColors.statusReady")
    public static let cyan = FlotillaPaletteCyan

    @available(*, deprecated, message: "Use EnvironmentValues.flotillaColors.canvas")
    public static let canvas = FlotillaPaletteCanvas

    @available(*, deprecated, message: "Use EnvironmentValues.flotillaColors.sidebar")
    public static let sidebar = FlotillaPaletteSidebar

    @available(*, deprecated, message: "Use EnvironmentValues.flotillaColors.surface")
    public static let panel = FlotillaPalettePanel

    @available(*, deprecated, message: "Use EnvironmentValues.flotillaColors.surfaceElevated")
    public static let elevated = FlotillaPaletteElevated

    @available(*, deprecated, message: "Use EnvironmentValues.flotillaColors.terminalCanvas")
    public static let terminal = FlotillaPaletteTerminal

    @available(*, deprecated, message: "Use EnvironmentValues.flotillaColors.separator")
    public static let subtleStroke = FlotillaPaletteSubtleStroke

    @available(*, deprecated, message: "Use EnvironmentValues.flotillaColors.textTertiary")
    public static let mutedText = FlotillaPaletteMutedText
}

// MARK: - Shared Components
public struct FlotillaPanel: ViewModifier {
    @Environment(\.flotillaColors) private var colors

    public init() {}

    public func body(content: Content) -> some View {
        content
            .background(colors.surface)
            .clipShape(RoundedRectangle(cornerRadius: FlotillaRadius.panel, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: FlotillaRadius.panel, style: .continuous)
                    .strokeBorder(colors.separator)
            }
    }
}

public extension View {
    func flotillaPanel() -> some View {
        modifier(FlotillaPanel())
    }
}

// Types are directly available in the module — no re-exports needed.
// Import DesignSystem to access: FlotillaTypography, FlotillaElevation, FlotillaMotion,
// StatusBadge, StatusBadgeSize, FlotillaBanner, FlotillaBannerStyle
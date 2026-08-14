import SwiftUI

public enum FlotillaSpacing {
    public static let xSmall: CGFloat = 4
    public static let small: CGFloat = 8
    public static let medium: CGFloat = 12
    public static let large: CGFloat = 16
    public static let xLarge: CGFloat = 24
    public static let xxLarge: CGFloat = 32
}

public enum FlotillaRadius {
    public static let small: CGFloat = 6
    public static let medium: CGFloat = 10
    public static let large: CGFloat = 14
}

public enum FlotillaPalette {
    /// Primary action color. The legacy name remains source-compatible with
    /// feature packages while the UI adopts Flotilla's warmer command-center accent.
    public static let ocean = Color(red: 0.96, green: 0.36, blue: 0.16)
    public static let signal = Color(red: 0.19, green: 0.78, blue: 0.64)
    public static let cyan = Color(red: 0.26, green: 0.72, blue: 0.92)
    public static let canvas = Color(red: 10 / 255, green: 10 / 255, blue: 12 / 255)
    public static let sidebar = Color(red: 18 / 255, green: 18 / 255, blue: 22 / 255)
    public static let panel = Color(red: 22 / 255, green: 22 / 255, blue: 26 / 255)
    public static let elevated = Color(red: 30 / 255, green: 30 / 255, blue: 35 / 255)
    public static let terminal = Color(red: 10 / 255, green: 10 / 255, blue: 12 / 255)
    public static let subtleStroke = Color(red: 50 / 255, green: 50 / 255, blue: 58 / 255)
    public static let mutedText = Color.white.opacity(0.52)
}

public struct FlotillaPanel: ViewModifier {
    public init() {}

    public func body(content: Content) -> some View {
        content
            .background(FlotillaPalette.panel)
            .clipShape(RoundedRectangle(cornerRadius: FlotillaRadius.small, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: FlotillaRadius.small, style: .continuous)
                    .strokeBorder(FlotillaPalette.subtleStroke)
            }
    }
}

public extension View {
    func flotillaPanel() -> some View {
        modifier(FlotillaPanel())
    }
}

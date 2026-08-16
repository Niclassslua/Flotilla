import SwiftUI

public struct FlotillaElevation: Sendable {
    public let y: CGFloat
    public let radius: CGFloat
    public let opacity: Double

    public static let level1 = FlotillaElevation(y: 2, radius: 4, opacity: 0.08)
    public static let level2 = FlotillaElevation(y: 4, radius: 8, opacity: 0.12)
    public static let level3 = FlotillaElevation(y: 10, radius: 22, opacity: 0.16)

    public init(y: CGFloat, radius: CGFloat, opacity: Double) {
        self.y = y
        self.radius = radius
        self.opacity = opacity
    }
}

public extension View {
    func flotillaShadow(_ elevation: FlotillaElevation, color: Color = .black) -> some View {
        shadow(color: color.opacity(elevation.opacity), radius: elevation.radius, x: 0, y: elevation.y)
    }

    func flotillaShadow(level: Int, color: Color = .black) -> some View {
        let elevation: FlotillaElevation
        switch level {
        case 1: elevation = .level1
        case 2: elevation = .level2
        case 3: elevation = .level3
        default: elevation = .level1
        }
        return flotillaShadow(elevation, color: color)
    }
}
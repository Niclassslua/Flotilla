import SwiftUI

public enum FlotillaTypography: Sendable {
    public static let display = Font.system(size: 28, weight: .semibold, design: .default)
    public static let title = Font.system(size: 22, weight: .semibold, design: .default)
    public static let headline = Font.system(size: 17, weight: .semibold, design: .default)
    public static let body = Font.system(size: 14, weight: .regular, design: .default)
    public static let callout = Font.system(size: 13, weight: .regular, design: .default)
    public static let caption = Font.system(size: 12, weight: .regular, design: .default)
    public static let caption2 = Font.system(size: 11, weight: .regular, design: .default)
    public static let caption3 = Font.system(size: 10, weight: .regular, design: .default)

    public enum Tracking: Sendable {
        public static let tight: CGFloat = -0.3
        public static let normal: CGFloat = 0
        public static let loose: CGFloat = 0.5
        public static let loose2: CGFloat = 0.7
        public static let loose3: CGFloat = 0.9
    }

    public enum Weight: Sendable {
        public static let light = Font.Weight.light
        public static let regular = Font.Weight.regular
        public static let medium = Font.Weight.medium
        public static let semibold = Font.Weight.semibold
        public static let bold = Font.Weight.bold
    }
}

public extension View {
    func flotillaFont(_ style: Font.TextStyle, size: CGFloat? = nil, weight: Font.Weight = .regular, tracking: CGFloat = 0) -> some View {
        let baseFont: Font
        switch style {
        case .largeTitle: baseFont = .system(size: size ?? 34, weight: weight, design: .default)
        case .title: baseFont = .system(size: size ?? 28, weight: weight, design: .default)
        case .title2: baseFont = .system(size: size ?? 22, weight: weight, design: .default)
        case .title3: baseFont = .system(size: size ?? 20, weight: weight, design: .default)
        case .headline: baseFont = .system(size: size ?? 17, weight: weight == .regular ? .semibold : weight, design: .default)
        case .subheadline: baseFont = .system(size: size ?? 15, weight: weight, design: .default)
        case .body: baseFont = .system(size: size ?? 14, weight: weight, design: .default)
        case .callout: baseFont = .system(size: size ?? 13, weight: weight, design: .default)
        case .caption: baseFont = .system(size: size ?? 12, weight: weight, design: .default)
        case .caption2: baseFont = .system(size: size ?? 11, weight: weight, design: .default)
        case .footnote: baseFont = .system(size: size ?? 13, weight: weight, design: .default)
        default: baseFont = .system(size: size ?? 14, weight: weight, design: .default)
        }
        return self.font(baseFont).tracking(tracking)
    }
}
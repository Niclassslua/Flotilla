import SwiftUI

/// The shared Flotilla wordmark: lowercase rounded lettering and the warm
/// accent period. Use it where the app name is presented as a visual brand.
public struct FlotillaWordmark: View {
    public let pointSize: CGFloat

    public init(pointSize: CGFloat = 18) {
        self.pointSize = pointSize
    }

    public var body: some View {
        (Text("flotilla") + Text(".").foregroundColor(FlotillaColors.accent))
            .font(.system(size: pointSize, weight: .heavy, design: .rounded))
            .tracking(-1)
            .foregroundStyle(FlotillaColors.textPrimary)
            .fixedSize()
            .accessibilityLabel("Flotilla")
    }
}

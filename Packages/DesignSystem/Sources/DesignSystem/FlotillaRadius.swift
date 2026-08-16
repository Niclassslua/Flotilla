import SwiftUI

public extension View {
    func flotillaCornerRadius(_ radius: CGFloat, style: RoundedCornerStyle = .continuous) -> some View {
        clipShape(RoundedRectangle(cornerRadius: radius, style: style))
    }

    func flotillaRoundedBorder(_ radius: CGFloat = FlotillaRadius.control, color: Color = Color(red: 50/255, green: 50/255, blue: 58/255), lineWidth: CGFloat = 1, style: RoundedCornerStyle = .continuous) -> some View {
        overlay(
            RoundedRectangle(cornerRadius: radius, style: style)
                .strokeBorder(color, lineWidth: lineWidth)
        )
    }
}
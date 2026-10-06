import SwiftUI

// Liquid Glass is iOS 26+. The companion supports iOS 18, so every glass call
// site goes through these wrappers, which fall back to the pre-26 system look
// (bordered buttons, material backgrounds).

extension View {
    /// `.buttonStyle(.glass)` / `.glassProminent` on iOS 26, `.bordered` /
    /// `.borderedProminent` before it.
    @ViewBuilder
    func companionGlassButtonStyle(prominent: Bool = false) -> some View {
        if #available(iOS 26.0, *) {
            if prominent {
                buttonStyle(.glassProminent)
            } else {
                buttonStyle(.glass)
            }
        } else {
            if prominent {
                buttonStyle(.borderedProminent)
            } else {
                buttonStyle(.bordered)
            }
        }
    }

    /// `.glassEffect(.regular…, in: shape)` on iOS 26, a regular-material
    /// background (plus the tint, if any) clipped to `shape` before it.
    @ViewBuilder
    func companionGlassEffect<S: Shape>(
        tint: Color? = nil,
        interactive: Bool = false,
        in shape: S
    ) -> some View {
        if #available(iOS 26.0, *) {
            glassEffect(Self.glass(tint: tint, interactive: interactive), in: shape)
        } else {
            background {
                shape
                    .fill(.regularMaterial)
                    .overlay { shape.fill(tint ?? .clear) }
            }
        }
    }

    @available(iOS 26.0, *)
    private static func glass(tint: Color?, interactive: Bool) -> Glass {
        var glass: Glass = .regular
        if let tint { glass = glass.tint(tint) }
        if interactive { glass = glass.interactive() }
        return glass
    }
}

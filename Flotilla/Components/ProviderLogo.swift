import SwiftUI
import AppKit
import SessionKit
import AgentKit

extension AgentKind {
    /// The asset name only. Prefer ``ProviderLogo`` over building an `Image`
    /// from this: the brand assets do not share an intrinsic size — most are
    /// vectors that scale to their container, but Codex is a 608×607 raster
    /// with no scale key, so an unconstrained `Image` renders it at 608pt and
    /// blows out whatever row it lands in.
    var logoImageName: String {
        AgentCatalog.descriptor(for: self).logoAssetName
    }
}

/// The provider's real brand mark (Claude, Codex/OpenAI, OpenCode, Antigravity), rendered
/// from vector assets in Assets.xcassets rather than a generic SF Symbol.
struct ProviderLogo: View {
    let agent: AgentKind

    var body: some View {
        Image(agent.logoImageName)
            .resizable()
            .aspectRatio(contentMode: .fit)
            .accessibilityHidden(true)
    }
}

extension ProviderLogo {
    /// A brand mark at a guaranteed point size, for anywhere AppKit does the
    /// sizing instead of SwiftUI layout.
    ///
    /// Both a `Menu`'s items and — under `.menuStyle(.borderlessButton)` — its
    /// *label* are rendered through AppKit, which sizes images itself and does
    /// not reliably honour a SwiftUI `.frame` on the view inside. That is
    /// survivable for the vector marks, which scale to whatever box they are
    /// given, and not for Codex: it is a 608×607 raster with no scale key in
    /// its `Contents.json`, so its intrinsic size is 608pt and it renders as a
    /// full-height banner across the row.
    ///
    /// Drawing into an explicitly sized `NSImage` removes the negotiation —
    /// the image *is* the requested size before SwiftUI or AppKit sees it.
    /// Use ``ProviderLogo`` itself anywhere SwiftUI owns the layout.
    static func fixedSize(for agent: AgentKind, size: CGFloat) -> Image {
        guard let source = NSImage(named: agent.logoImageName) else {
            return Image(systemName: "square.dashed")
        }
        let target = NSSize(width: size, height: size)
        let scaled = NSImage(size: target, flipped: false) { rect in
            source.draw(
                in: rect,
                from: .zero,
                operation: .sourceOver,
                fraction: 1,
                respectFlipped: true,
                hints: [.interpolation: NSImageInterpolation.high]
            )
            return true
        }
        scaled.size = target
        return Image(nsImage: scaled)
    }
}

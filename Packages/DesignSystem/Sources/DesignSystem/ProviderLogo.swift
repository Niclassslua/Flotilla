import SwiftUI
import SessionKit
#if os(macOS)
import AppKit
#endif

/// The brand marks shipped in this package's asset catalog, shared by the Mac
/// app and the iOS companion.
///
/// Prefer ``ProviderLogo`` over building an `Image` from ``image``: the brand
/// assets do not share an intrinsic size — most are vectors that scale to their
/// container, but Codex is a 608×607 raster with no scale key, so an
/// unconstrained `Image` renders it at 608pt and blows out whatever row it
/// lands in.
public enum ProviderLogoAsset: String, CaseIterable, Sendable {
    case claude = "ProviderLogoClaude"
    case codex = "ProviderLogoCodex"
    case openCode = "ProviderLogoOpenCode"
    case antigravity = "ProviderLogoAntigravity"
    case cursor = "ProviderLogoCursor"

    public init(agent: AgentKind) {
        switch agent {
        case .claudeCode: self = .claude
        case .codexCLI: self = .codex
        case .openCode: self = .openCode
        case .antigravity: self = .antigravity
        case .cursorAgent: self = .cursor
        }
    }

    public var image: Image {
        Image(rawValue, bundle: .module)
    }

    #if os(macOS)
    /// For AppKit call sites. The assets live in this package's bundle, so
    /// `NSImage(named:)` against the main bundle no longer finds them.
    public var nsImage: NSImage? {
        Bundle.module.image(forResource: rawValue)
    }
    #endif
}

/// The provider's real brand mark (Claude, Codex/OpenAI, OpenCode, Antigravity),
/// rendered from vector assets rather than a generic SF Symbol.
public struct ProviderLogo: View {
    public let agent: AgentKind

    public init(agent: AgentKind) {
        self.agent = agent
    }

    public var body: some View {
        ProviderLogoAsset(agent: agent).image
            .resizable()
            .aspectRatio(contentMode: .fit)
            .accessibilityHidden(true)
    }
}

#if os(macOS)
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
    public static func fixedSize(for agent: AgentKind, size: CGFloat) -> Image {
        guard let source = ProviderLogoAsset(agent: agent).nsImage else {
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
#endif

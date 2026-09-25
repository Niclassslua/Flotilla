import SwiftUI
import SessionKit
import DesignSystem

public enum StatusBadgeSize {
    case micro
    case small
    case medium

    var dotSize: CGFloat {
        switch self {
        case .micro: return 6
        case .small: return 8
        case .medium: return 10
        }
    }

    var font: Font {
        switch self {
        case .micro: return .caption2
        case .small: return .caption
        case .medium: return .callout
        }
    }

    var spacing: CGFloat {
        switch self {
        case .micro: return 3
        case .small: return 4
        case .medium: return 6
        }
    }

    var horizontalPadding: CGFloat {
        switch self {
        case .micro: return 4
        case .small: return 6
        case .medium: return 8
        }
    }

    var verticalPadding: CGFloat {
        switch self {
        case .micro: return 2
        case .small: return 3
        case .medium: return 4
        }
    }
}

public struct StatusBadge: View {
    /// `nil` — no status observed yet — renders nothing at all.
    private let status: SessionStatus?
    private let waitingReason: SessionWaitingReason?
    private let size: StatusBadgeSize
    private let showLabel: Bool

    public init(
        _ status: SessionStatus?,
        waitingReason: SessionWaitingReason? = nil,
        size: StatusBadgeSize = .small,
        showLabel: Bool = true
    ) {
        self.status = status
        self.waitingReason = status == .waitingForInput ? waitingReason : nil
        self.size = size
        self.showLabel = showLabel
    }

    private var statusColor: Color {
        StatusPresentation.color(for: status)
    }

    private var statusLabel: String {
        StatusPresentation.label(for: status, waitingReason: waitingReason)
    }

    @ViewBuilder
    public var body: some View {
        if status != nil {
            badgeBody
        }
    }

    private var badgeBody: some View {
        HStack(spacing: size.spacing) {
            // One filled disc, nothing behind it. There used to be a
            // same-sized stroked circle underneath as a pulse halo, and the
            // filled dot's own knockout border shrank it just enough to leave
            // the stroke showing — so a single status read as two rings.
            //
            // The halo left behind a `repeatForever` pulse animation on the
            // whole badge with nothing bound to it, so the transaction latched
            // onto the badge's *layout* instead and every `.working` row
            // flowed in on an endless loop. Nothing here animates — if a pulse
            // comes back, bind it to a property on this circle (see the beacon
            // in `SessionRow`), never to the badge as a whole.
            Circle()
                .fill(statusColor)
                .frame(width: size.dotSize, height: size.dotSize)
                .frame(width: size.dotSize + 4, height: size.dotSize + 4)

            if showLabel {
                Text(statusLabel)
                    .font(size.font.weight(.medium))
                    .foregroundStyle(statusColor)
                    .lineLimit(1)
            }
        }
        .padding(.horizontal, size.horizontalPadding)
        .padding(.vertical, size.verticalPadding)
        // A solid-enough capsule fill keeps the pill shape readable on liquid
        // glass hero washes; a near-transparent tint can read as a square blot.
        .background {
            Capsule(style: .continuous)
                .fill(statusColor.opacity(0.18))
        }
        .accessibilityLabel(statusLabel)
        .accessibilityAddTraits(status == .waitingForInput ? [.updatesFrequently] : [])
    }
}

public extension StatusBadge {
    init(
        _ status: SessionStatus?,
        waitingReason: SessionWaitingReason? = nil,
        variant: Variant = .default
    ) {
        switch variant {
        case .default:
            self.init(status, waitingReason: waitingReason, size: .small, showLabel: true)
        case .compact:
            self.init(status, waitingReason: waitingReason, size: .micro, showLabel: false)
        case .inline:
            self.init(status, waitingReason: waitingReason, size: .small, showLabel: true)
        case .prominent:
            self.init(status, waitingReason: waitingReason, size: .medium, showLabel: true)
        }
    }

    enum Variant {
        case `default`
        case compact
        case inline
        case prominent
    }
}

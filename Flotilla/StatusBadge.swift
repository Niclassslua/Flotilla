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
    private let status: SessionStatus
    private let size: StatusBadgeSize
    private let showLabel: Bool
    private let showGlyph: Bool

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isPulsing = false

    public init(
        _ status: SessionStatus,
        size: StatusBadgeSize = .small,
        showLabel: Bool = true,
        showGlyph: Bool = false
    ) {
        self.status = status
        self.size = size
        self.showLabel = showLabel
        self.showGlyph = showGlyph
    }

    private var statusColor: Color {
        switch status {
        case .working: return FlotillaColors.statusWorking
        case .idle: return FlotillaColors.statusIdle
        case .waitingForInput: return FlotillaColors.statusWaitingForInput
        case .ready: return FlotillaColors.statusReady
        case .finished: return FlotillaColors.statusFinished
        case .crashed: return FlotillaColors.statusCrashed
        }
    }

    private var statusLabel: String {
        switch status {
        case .working: return "Working"
        case .idle: return "Idle"
        case .waitingForInput: return "Waiting for Input"
        case .ready: return "Ready"
        case .finished: return "Finished"
        case .crashed: return "Crashed"
        }
    }

    private var statusGlyph: String {
        switch status {
        case .working: return "gearshape.2"
        case .idle: return "circle"
        case .waitingForInput: return "exclamationmark.circle"
        case .ready: return "hand.raised"
        case .finished: return "checkmark.circle"
        case .crashed: return "xmark.octagon"
        }
    }

    private var shouldPulse: Bool {
        status == .working && !reduceMotion
    }

    public var body: some View {
        HStack(spacing: size.spacing) {
            ZStack {
                Circle()
                    .stroke(statusColor, lineWidth: size == .micro ? 1 : 1.5)
                    .frame(width: size.dotSize, height: size.dotSize)
                    .scaleEffect(isPulsing ? (size == .micro ? 1.8 : 2.2) : 1)
                    .opacity(isPulsing ? 0 : (size == .micro ? 0.4 : 0.55))
                    .opacity(shouldPulse ? 1 : 0)

                Circle()
                    .fill(statusColor)
                    .frame(width: size.dotSize, height: size.dotSize)
                    .shadow(color: statusColor.opacity(0.45), radius: shouldPulse ? 3 : 0)
            }
            .frame(width: size.dotSize + 4, height: size.dotSize + 4)

            if showGlyph {
                Image(systemName: statusGlyph)
                    .font(.system(size: size.dotSize * 0.7, weight: .medium))
                    .foregroundStyle(statusColor)
            }

            if showLabel {
                Text(statusLabel)
                    .font(size.font.weight(.medium))
                    .foregroundStyle(statusColor)
                    .lineLimit(1)
            }
        }
        .padding(.horizontal, size.horizontalPadding)
        .padding(.vertical, size.verticalPadding)
        .background(statusColor.opacity(0.1), in: Capsule())
        .animation(pulseAnimation, value: isPulsing)
        .onAppear { isPulsing = shouldPulse }
        .onChange(of: shouldPulse) { _, pulsing in isPulsing = pulsing }
        .accessibilityLabel(statusLabel)
        .accessibilityAddTraits(status == .waitingForInput ? [.updatesFrequently] : [])
    }

    private var pulseAnimation: Animation? {
        isPulsing ? .easeOut(duration: 1.1).repeatForever(autoreverses: false) : nil
    }
}

public extension StatusBadge {
    init(
        _ status: SessionStatus,
        variant: Variant = .default
    ) {
        switch variant {
        case .default:
            self.init(status, size: .small, showLabel: true, showGlyph: false)
        case .compact:
            self.init(status, size: .micro, showLabel: false, showGlyph: true)
        case .inline:
            self.init(status, size: .small, showLabel: true, showGlyph: false)
        case .prominent:
            self.init(status, size: .medium, showLabel: true, showGlyph: true)
        }
    }

    enum Variant {
        case `default`
        case compact
        case inline
        case prominent
    }
}
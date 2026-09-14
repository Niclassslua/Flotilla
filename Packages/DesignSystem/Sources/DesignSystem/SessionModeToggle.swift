import SwiftUI
import SessionKit

/// A single "Plan" toggle: off is the resting, regular (act) mode; on
/// switches the session into plan mode. Modeled as one button rather than an
/// Act/Plan segmented pair, since there are only two states and one of them
/// (act) is already the default — the control only needs to say what's
/// different about *this* session, not restate the default.
public struct SessionModeToggle: View {
    @Binding private var mode: SessionMode
    private let accessibilityIdentifier: String

    public init(mode: Binding<SessionMode>, accessibilityIdentifier: String) {
        self._mode = mode
        self.accessibilityIdentifier = accessibilityIdentifier
    }

    private var isPlanning: Bool { mode == .plan }

    public var body: some View {
        Button {
            mode = isPlanning ? .act : .plan
        } label: {
            HStack(spacing: FlotillaSpacing.xSmall) {
                Image(systemName: SessionMode.plan.symbolName)
                    .font(.system(size: FlotillaIconSize.xSmall))
                Text(SessionMode.plan.displayName)
                    .font(FlotillaTypography.caption3.weight(.medium))
            }
            .foregroundStyle(isPlanning ? FlotillaColors.accentContent : FlotillaColors.textTertiary)
            .padding(.horizontal, FlotillaSpacing.small)
            .padding(.vertical, 3)
            .background(isPlanning ? FlotillaColors.accent : FlotillaColors.surfaceElevated, in: Capsule())
            .overlay(Capsule().strokeBorder(
                isPlanning ? .clear : FlotillaColors.separator,
                lineWidth: FlotillaBorderWidth.hairline
            ))
        }
        .buttonStyle(.plain)
        .help("Plan mode — the agent reads and proposes without making changes")
        .accessibilityIdentifier(accessibilityIdentifier)
        .accessibilityAddTraits(isPlanning ? [.isSelected] : [])
        .accessibilityValue(isPlanning ? "On" : "Off")
    }
}

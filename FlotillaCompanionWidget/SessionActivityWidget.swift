import ActivityKit
import DesignSystem
import SwiftUI
import WidgetKit

/// -proto liveActivity: the Dynamic Island and Lock Screen presentation for
/// a session's live status. Local-only — see SessionActivityAttributes.
struct SessionActivityWidget: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: SessionActivityAttributes.self) { context in
            LockScreenView(attributes: context.attributes, state: context.state)
                .activityBackgroundTint(FlotillaColors.canvas)
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    Circle()
                        .fill(context.state.statusKind.color)
                        .frame(width: 10, height: 10)
                        .padding(.leading, 4)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    Text(context.state.startedAt, style: .timer)
                        .font(.caption.monospacedDigit().weight(.semibold))
                        .foregroundStyle(.secondary)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(context.attributes.title)
                            .font(.subheadline.weight(.semibold))
                            .lineLimit(1)
                        Text("\(context.state.statusLabel) · \(context.attributes.agentDisplayName)")
                            .font(.caption)
                            .foregroundStyle(context.state.statusKind.color)
                    }
                }
            } compactLeading: {
                Circle()
                    .fill(context.state.statusKind.color)
                    .frame(width: 10, height: 10)
            } compactTrailing: {
                Text(context.state.startedAt, style: .timer)
                    .font(.caption2.monospacedDigit().weight(.semibold))
                    .foregroundStyle(.white)
            } minimal: {
                Circle()
                    .fill(context.state.statusKind.color)
            }
        }
    }
}

private struct LockScreenView: View {
    let attributes: SessionActivityAttributes
    let state: SessionActivityAttributes.ContentState

    var body: some View {
        HStack(spacing: 10) {
            Circle()
                .fill(state.statusKind.color)
                .frame(width: 10, height: 10)
            VStack(alignment: .leading, spacing: 2) {
                Text(attributes.title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(FlotillaColors.textPrimary)
                    .lineLimit(1)
                Text("\(state.statusLabel) · \(attributes.agentDisplayName)")
                    .font(.caption)
                    .foregroundStyle(FlotillaColors.textSecondary)
            }
            Spacer()
            Text(state.startedAt, style: .timer)
                .font(.caption.monospacedDigit().weight(.semibold))
                .foregroundStyle(state.statusKind.color)
        }
        .padding(16)
    }
}

private extension SessionActivityAttributes.StatusKind {
    var color: Color {
        switch self {
        case .working: FlotillaColors.statusWorking
        case .waitingForInput: FlotillaColors.statusWaitingForInput
        case .readyForReview: FlotillaColors.statusReady
        case .crashed: FlotillaColors.statusCrashed
        }
    }

}

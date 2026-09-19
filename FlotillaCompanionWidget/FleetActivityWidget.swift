import ActivityKit
import DesignSystem
import SessionKit
import SwiftUI
import WidgetKit

/// "Fleet Radar": the Dynamic Island and Lock Screen presentation of a
/// Mac's whole fleet. The compact island is a headcount, the expanded one a
/// strip with a segment per session over the most urgent one. Local-only —
/// see FleetActivityAttributes.
struct FleetActivityWidget: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: FleetActivityAttributes.self) { context in
            FleetLockScreenView(attributes: context.attributes, state: context.state, isLive: context.isLive)
                .environment(\.colorScheme, .dark)
                .activityBackgroundTint(.black.opacity(0.55))
                .activitySystemActionForegroundColor(.white)
                .widgetURL(FleetActivityLink.fleet(context.attributes.macID))
        } dynamicIsland: { context in
            let state = context.state
            let isLive = context.isLive
            let focus = state.sessions.first
            return DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    HStack(alignment: .firstTextBaseline, spacing: 5) {
                        Text("\(state.activeCount)")
                            .font(.system(size: 26, weight: .bold, design: .rounded))
                        Text("active")
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(.white.opacity(0.55))
                    }
                    .padding(.leading, 6)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    FleetSourceLabel(macName: context.attributes.macName, state: state, isLive: isLive)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.white.opacity(0.5))
                        .padding(.trailing, 6)
                        .frame(maxHeight: .infinity)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    // The system already spaces this region from the header
                    // above; the gap under the strip matches it.
                    VStack(alignment: .leading, spacing: 19) {
                        FleetStrip(sessions: state.sessions, isLive: isLive)
                        if let focus {
                            FleetFocusRow(session: focus, isLive: isLive)
                        }
                    }
                    .padding(.horizontal, 6)
                }
            } compactLeading: {
                FleetDots(sessions: state.sessions, isLive: isLive)
            } compactTrailing: {
                FleetHeadcount(state: state, isLive: isLive)
            } minimal: {
                FleetDonut(sessions: state.sessions, isLive: isLive)
            }
            .widgetURL(focus.map { FleetActivityLink.session($0.id) } ?? FleetActivityLink.fleet(context.attributes.macID))
            .keylineTint(focus?.status.color ?? .white)
        }
    }
}

// MARK: - Lock Screen

private struct FleetLockScreenView: View {
    let attributes: FleetActivityAttributes
    let state: FleetActivityAttributes.ContentState
    let isLive: Bool

    private var remainingCount: Int {
        max(0, state.activeCount - state.visibleSessions.count)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(alignment: .firstTextBaseline) {
                FlotillaWordmark(pointSize: 15)
                Spacer(minLength: 8)
                FleetSourceLabel(macName: attributes.macName, state: state, isLive: isLive, showsCount: true)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.white.opacity(0.5))
            }
            ForEach(state.visibleSessions) { session in
                Link(destination: FleetActivityLink.session(session.id)) {
                    FleetRow(session: session, isLive: isLive)
                }
            }
            if remainingCount > 0 {
                FleetMoreSessionsRow(macID: attributes.macID, remainingCount: remainingCount)
            }
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }
}

/// Shown when there are more active sessions than fit on the Lock Screen.
/// Tapping the button or row opens the fleet overview in the companion app.
private struct FleetMoreSessionsRow: View {
    let macID: String
    let remainingCount: Int

    var body: some View {
        Link(destination: FleetActivityLink.fleet(macID)) {
            HStack(spacing: 6) {
                Text(remainingCount == 1 ? "+1 more session running" : "+\(remainingCount) more sessions running")
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(.white.opacity(0.6))
                    .lineLimit(1)
                Spacer(minLength: 8)
                HStack(spacing: 4) {
                    Text("All Sessions")
                        .font(.system(size: 11, weight: .semibold))
                    Image(systemName: "arrow.right")
                        .font(.system(size: 9, weight: .bold))
                }
                .foregroundStyle(.white)
                .padding(.horizontal, 9)
                .padding(.vertical, 3.5)
                .background(.white.opacity(0.14), in: Capsule())
            }
            .contentShape(Rectangle())
        }
    }
}

private struct FleetRow: View {
    let session: FleetActivityAttributes.Session
    let isLive: Bool

    var body: some View {
        HStack(spacing: 9) {
            FleetBadgedLogo(session: session, isLive: isLive, size: 20)
            VStack(alignment: .leading, spacing: 0) {
                Text(session.title)
                    .font(.system(size: 13, weight: .semibold))
                    .lineLimit(1)
                Text(session.detail)
                    .font(.system(size: 11))
                    .foregroundStyle(session.status.color)
                    .lineLimit(1)
            }
            Spacer(minLength: 6)
            FleetElapsed(session: session, isLive: isLive)
                .font(.system(size: 12, weight: .medium).monospacedDigit())
                .foregroundStyle(.white.opacity(0.5))
        }
    }
}

// MARK: - Dynamic Island

private struct FleetFocusRow: View {
    let session: FleetActivityAttributes.Session
    let isLive: Bool

    var body: some View {
        HStack(spacing: 10) {
            FleetBadgedLogo(session: session, isLive: isLive, size: 22)
            VStack(alignment: .leading, spacing: 1) {
                Text(session.title)
                    .font(.system(size: 14, weight: .semibold))
                    .lineLimit(1)
                Text(session.detail)
                    .font(.system(size: 11.5, design: session.status.needsYou ? .monospaced : .default))
                    .foregroundStyle(.white.opacity(0.55))
                    .lineLimit(1)
            }
            Spacer(minLength: 6)
            Link(destination: FleetActivityLink.session(session.id)) {
                Text("Open")
                    .font(.system(size: 13, weight: .semibold))
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(session.status.color.opacity(0.22), in: Capsule())
                    .foregroundStyle(session.status.color)
            }
        }
    }
}

/// One segment per session, most urgent first.
private struct FleetStrip: View {
    let sessions: [FleetActivityAttributes.Session]
    let isLive: Bool

    var body: some View {
        HStack(spacing: 3) {
            ForEach(sessions) { session in
                RoundedRectangle(cornerRadius: 3, style: .continuous)
                    .fill(session.status.color.opacity(isLive ? 1 : 0.4))
            }
        }
        .frame(height: 6)
    }
}

/// Overlapping status dots, one per session, for the compact island.
private struct FleetDots: View {
    let sessions: [FleetActivityAttributes.Session]
    let isLive: Bool

    private static let maxDots = 4
    private static let size: CGFloat = 11

    var body: some View {
        HStack(spacing: -Self.size * 0.35) {
            ForEach(sessions.prefix(Self.maxDots)) { session in
                Circle()
                    .fill(session.status.color)
                    .frame(width: Self.size, height: Self.size)
                    .overlay(Circle().stroke(.black, lineWidth: 2))
            }
        }
        .opacity(isLive ? 1 : 0.45)
        .padding(.leading, 4)
    }
}

/// Who needs you, otherwise how many are busy.
private struct FleetHeadcount: View {
    let state: FleetActivityAttributes.ContentState
    let isLive: Bool

    var body: some View {
        Group {
            if state.needsYouCount > 0 {
                HStack(spacing: 3) {
                    Image(systemName: "hand.raised.fill")
                        .font(.system(size: 11, weight: .bold))
                    Text("\(state.needsYouCount)")
                        .font(.system(size: 14, weight: .bold, design: .rounded))
                }
                .foregroundStyle(FleetActivityAttributes.Status.waiting.color)
            } else if state.workingCount > 0 {
                Text("\(state.workingCount) busy")
                    .font(.system(size: 12, weight: .semibold, design: .rounded))
                    .foregroundStyle(FleetActivityAttributes.Status.working.color)
            } else {
                Image(systemName: "checkmark")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(FleetActivityAttributes.Status.ready.color)
            }
        }
        .opacity(isLive ? 1 : 0.45)
        .padding(.trailing, 4)
    }
}

/// The fleet's status mix as a ring, for the minimal island.
private struct FleetDonut: View {
    let sessions: [FleetActivityAttributes.Session]
    let isLive: Bool

    private static let gap = 0.02

    var body: some View {
        let slice = 1 / Double(max(sessions.count, 1))
        ZStack {
            ForEach(Array(sessions.enumerated()), id: \.element.id) { index, session in
                Circle()
                    .trim(from: Double(index) * slice, to: Double(index + 1) * slice - (sessions.count > 1 ? Self.gap : 0))
                    .stroke(session.status.color, style: StrokeStyle(lineWidth: 3.5, lineCap: .butt))
            }
        }
        .rotationEffect(.degrees(-90))
        .frame(width: 18, height: 18)
        .opacity(isLive ? 1 : 0.45)
    }
}

// MARK: - Shared

/// The provider logo with its status dot on the bottom-trailing corner —
/// the same badge the companion's session rows use.
private struct FleetBadgedLogo: View {
    let session: FleetActivityAttributes.Session
    let isLive: Bool
    let size: CGFloat

    /// The companion's 8 pt dot on a 22 pt logo, kept in proportion.
    private var dotSize: CGFloat { (size * 8 / 22).rounded() }

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            FleetProviderLogo(agent: session.agent)
                .frame(width: size, height: size)
            Circle()
                .fill(session.status.color.opacity(isLive ? 1 : 0.45))
                .frame(width: dotSize, height: dotSize)
                // Cuts the dot out of the logo, as on the companion's rows.
                .background(Circle().fill(.black).frame(width: dotSize + 3, height: dotSize + 3))
                .offset(x: 3, y: 3)
        }
    }
}

/// `ProviderLogo`, adjusted for the island's black. Codex ships as a 608 pt
/// raster, over the size a Live Activity will decode, so the widget carries
/// its own small copy; OpenCode's black mark is inverted to stay visible.
private struct FleetProviderLogo: View {
    let agent: AgentKind

    var body: some View {
        switch agent {
        case .codexCLI:
            Image("WidgetProviderLogoCodex")
                .resizable()
                .aspectRatio(contentMode: .fit)
                .accessibilityHidden(true)
        case .openCode:
            ProviderLogo(agent: agent).colorInvert()
        case .claudeCode, .antigravity:
            ProviderLogo(agent: agent)
        }
    }
}

/// The Mac's name while live; when the snapshot has frozen, when it was taken.
private struct FleetSourceLabel: View {
    let macName: String
    let state: FleetActivityAttributes.ContentState
    let isLive: Bool
    var showsCount = false

    var body: some View {
        if isLive {
            HStack(spacing: 4) {
                Image(systemName: "laptopcomputer")
                Text(showsCount ? "\(macName) · \(state.activeCount) active" : macName)
                    .lineLimit(1)
            }
        } else {
            HStack(spacing: 4) {
                Image(systemName: "pause.fill")
                Text("\(macName) · as of \(state.updatedAt, style: .time)")
                    .lineLimit(1)
            }
        }
    }
}

/// Time in the current status. Frozen snapshots show no clock, since one
/// that kept ticking would claim the session is still in that state.
private struct FleetElapsed: View {
    let session: FleetActivityAttributes.Session
    let isLive: Bool

    var body: some View {
        if session.status == .ready {
            Image(systemName: "checkmark")
                .foregroundStyle(session.status.color)
        } else if isLive {
            // A timer text claims all the width it's offered; pin it.
            Text(timerInterval: session.since...Date.distantFuture, countsDown: false)
                .lineLimit(1)
                .multilineTextAlignment(.trailing)
                .frame(width: 56, alignment: .trailing)
        }
    }
}

private extension ActivityViewContext<FleetActivityAttributes> {
    /// Frozen once the Mac drops off, or once the stale date the app sets on
    /// its way into the background passes.
    var isLive: Bool { state.isLive && !isStale }
}

extension FleetActivityAttributes.Status {
    var color: Color {
        switch self {
        case .waiting: FlotillaColors.statusWaitingForInput
        case .crashed: FlotillaColors.statusCrashed
        case .working: FlotillaColors.statusWorking
        case .ready: FlotillaColors.statusReady
        }
    }
}

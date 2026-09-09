import SwiftUI
import SessionKit
import DesignSystem

/// Where a finished review is sent.
enum ReviewDestination: Identifiable, Equatable {
    /// A session that is already running: the review goes into its live agent,
    /// which keeps the conversation that produced the code.
    case runningSession(Session)
    /// A fresh session with the chosen agent, started from the review.
    case newSession(AgentKind)

    var id: String {
        switch self {
        case let .runningSession(session): "session-\(session.id.uuidString)"
        case let .newSession(agent): "agent-\(agent.rawValue)"
        }
    }

    var label: String {
        switch self {
        case let .runningSession(session): session.title
        case let .newSession(agent): agent.displayName
        }
    }
}

/// Picks a destination for the review and shows what will be sent.
///
/// Follows the handoff menu's shape — sectioned, one row per target, a brand
/// mark per agent — and, like it, sends on selection rather than adding a
/// second confirmation step.
struct ReviewSendSheet: View {
    let reviewedSession: Session
    let candidates: [Session]
    let prompt: String
    let commentCount: Int
    let onSend: (ReviewDestination) -> Void
    let onCancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()

            HStack(alignment: .top, spacing: 0) {
                destinations
                Divider()
                preview
            }

            Divider()
            footer
        }
        .frame(width: 720, height: 460)
        .background(FlotillaColors.canvas)
        .accessibilityIdentifier(AXID.reviewSendSheet.rawValue)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("Send Review")
                .font(FlotillaTypography.headline)
                .foregroundStyle(FlotillaColors.textPrimary)
            Text("\(commentCount) unsent comment\(commentCount == 1 ? "" : "s") on \(reviewedSession.title)")
                .font(FlotillaTypography.caption)
                .foregroundStyle(FlotillaColors.textSecondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(FlotillaSpacing.large)
    }

    private var destinations: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: FlotillaSpacing.medium) {
                if !candidates.isEmpty {
                    section("Continue in a running session") {
                        ForEach(candidates) { session in
                            row(.runningSession(session), agent: session.agent, detail: detail(for: session))
                        }
                    }
                }

                section("Start a new session") {
                    ForEach(AgentKind.allCases) { agent in
                        row(.newSession(agent), agent: agent, detail: "New session in this worktree")
                    }
                }
            }
            .padding(FlotillaSpacing.medium)
        }
        .frame(width: 320)
    }

    private func section(
        _ title: String,
        @ViewBuilder content: () -> some View
    ) -> some View {
        VStack(alignment: .leading, spacing: FlotillaSpacing.xSmall) {
            Text(title.uppercased())
                .font(FlotillaTypography.caption3.weight(.semibold))
                .foregroundStyle(FlotillaColors.textTertiary)
                .kerning(FlotillaTypography.Tracking.loose)
                .padding(.horizontal, FlotillaSpacing.small)
            content()
        }
    }

    private func row(_ destination: ReviewDestination, agent: AgentKind, detail: String) -> some View {
        Button {
            onSend(destination)
        } label: {
            HStack(spacing: FlotillaSpacing.small) {
                ProviderLogo.fixedSize(for: agent, size: 16)
                VStack(alignment: .leading, spacing: 1) {
                    Text(destination.label)
                        .font(FlotillaTypography.caption.weight(.medium))
                        .foregroundStyle(FlotillaColors.textPrimary)
                        .lineLimit(1)
                    Text(detail)
                        .font(FlotillaTypography.caption3)
                        .foregroundStyle(FlotillaColors.textTertiary)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, FlotillaSpacing.small)
            .padding(.vertical, FlotillaSpacing.small)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                FlotillaColors.surface,
                in: RoundedRectangle(cornerRadius: FlotillaRadius.control, style: .continuous)
            )
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier(AXID.reviewSendDestination(destination.label))
    }

    private func detail(for session: Session) -> String {
        session.id == reviewedSession.id
            ? "The agent that wrote this code"
            : session.agent.displayName
    }

    private var preview: some View {
        ScrollView {
            Text(prompt)
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(FlotillaColors.textSecondary)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(FlotillaSpacing.medium)
        }
        .frame(maxWidth: .infinity)
    }

    private var footer: some View {
        HStack {
            Text("Sent comments stay in the review, marked as sent.")
                .font(FlotillaTypography.caption2)
                .foregroundStyle(FlotillaColors.textTertiary)
            Spacer()
            Button("Cancel", action: onCancel)
                .keyboardShortcut(.cancelAction)
        }
        .padding(FlotillaSpacing.medium)
    }
}

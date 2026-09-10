import SwiftUI
import SessionKit
import DesignSystem

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
    let onSend: (Session) -> Void
    let onSendToNewAgent: (AgentKind) -> Void
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
                if candidates.isEmpty {
                    Text("No running session is available — start a new agent instead.")
                        .font(FlotillaTypography.caption)
                        .foregroundStyle(FlotillaColors.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(FlotillaSpacing.small)
                } else {
                    section("Continue in a running session") {
                        ForEach(candidates) { session in
                            row(session, detail: detail(for: session))
                        }
                    }
                }

                section("Start a new agent") {
                    ForEach(orderedAgents) { kind in
                        newAgentRow(kind)
                    }
                }
            }
            .padding(FlotillaSpacing.medium)
        }
        .frame(width: 320)
    }

    /// The reviewed session's own agent first, then the rest in catalogue
    /// order — same-agent is the common choice, but any agent is allowed.
    private var orderedAgents: [AgentKind] {
        let mine = reviewedSession.agent
        return [mine] + AgentKind.allCases.filter { $0 != mine }
    }

    private func newAgentRow(_ kind: AgentKind) -> some View {
        Button {
            onSendToNewAgent(kind)
        } label: {
            HStack(spacing: FlotillaSpacing.small) {
                ZStack {
                    ProviderLogo.fixedSize(for: kind, size: 16)
                    Image(systemName: "plus.circle.fill")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(FlotillaColors.accent)
                        .background(FlotillaColors.canvas, in: Circle())
                        .offset(x: 7, y: 7)
                }
                .frame(width: 16, height: 16)

                VStack(alignment: .leading, spacing: 1) {
                    Text("New \(kind.displayName) agent")
                        .font(FlotillaTypography.caption.weight(.medium))
                        .foregroundStyle(FlotillaColors.textPrimary)
                        .lineLimit(1)
                    Text(kind == reviewedSession.agent
                         ? "Same agent, fresh context — review as its task"
                         : "Fresh session on this branch, review as its task")
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
        .accessibilityIdentifier(AXID.reviewSendDestination("New \(kind.displayName)"))
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

    private func row(_ session: Session, detail: String) -> some View {
        Button {
            onSend(session)
        } label: {
            HStack(spacing: FlotillaSpacing.small) {
                ProviderLogo.fixedSize(for: session.agent, size: 16)
                VStack(alignment: .leading, spacing: 1) {
                    Text(session.title)
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
        .accessibilityIdentifier(AXID.reviewSendDestination(session.title))
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

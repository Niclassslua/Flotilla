import SwiftUI
import SessionKit
import DesignSystem
import CompanionKit

/// The one place anything that needs the user appears.
///
/// A pending card *replaces* the text field, so a prompt can never be typed
/// into an open dialog — which on Claude Code would approve it (probe hazard F).
struct ComposerSlot: View {
    let session: CompanionSession
    let transcript: SessionTranscript
    let pending: [PendingInteraction]
    let isActionable: Bool
    let maxCardHeight: CGFloat

    var body: some View {
        VStack(spacing: 8) {
            if let top = pending.first {
                if let resolution = top.resolution {
                    ResolutionNotice(resolution: resolution)
                        .transition(.scale(scale: 0.96).combined(with: .opacity))
                } else {
                    card(for: top, position: 1, count: pending.count)
                        .id(top.id)
                        .transition(.asymmetric(insertion: .move(edge: .bottom).combined(with: .opacity), removal: .opacity))
                }
            } else if session.status == .crashed {
                CrashedCard(sessionID: session.id, reason: session.crashReason, isActionable: isActionable)
            } else {
                if session.status == .readyForReview, !session.reviewAcknowledged, let stat = session.diffStat, stat.hasChanges {
                    ReviewChangesCard(sessionID: session.id, stat: stat)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }
                PromptComposer(session: session, isStopping: transcript.isStopping, isActionable: isActionable)
            }
        }
        .padding(.horizontal, 12)
        .padding(.top, 8)
        .padding(.bottom, 8)
        .animation(.snappy, value: pending.map(\.id))
        .animation(.snappy, value: pending.first?.resolution)
        .animation(.snappy, value: session.status)
        .animation(.snappy, value: session.reviewAcknowledged)
    }

    @ViewBuilder
    private func card(for interaction: PendingInteraction, position: Int, count: Int) -> some View {
        let context = CardContext(sessionID: session.id, interaction: interaction, agent: session.agent, position: position, count: count, isActionable: isActionable)
        switch interaction.kind {
        case .permission(let request):
            PermissionCard(context: context, request: request)
        case .question(let steps):
            QuestionCard(context: context, steps: steps, maxHeight: maxCardHeight)
        case .plan(let plan):
            PlanCard(context: context, plan: plan)
        case .needsTerminal(let title):
            NeedsTerminalCard(dialogTitle: title)
        }
    }
}

/// What every card needs to know about where it sits.
struct CardContext {
    let sessionID: CompanionSession.ID
    let interaction: PendingInteraction
    let agent: AgentKind
    let position: Int
    let count: Int
    let isActionable: Bool

    var capabilities: ProviderCapabilities { .of(agent) }
}

/// Shared card chrome: kind label, subagent badge, `1 of 3` counter.
struct CardContainer<Content: View>: View {
    let context: CardContext?
    let title: String
    let systemImage: String
    var tint: Color = FlotillaColors.statusWaitingForInput
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Label(title, systemImage: systemImage)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(tint)
                if let subagent = context?.interaction.subagent {
                    Text("Subagent · \(subagent)")
                        .font(.caption2.weight(.medium))
                        .foregroundStyle(FlotillaColors.textSecondary)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(FlotillaColors.surfaceElevated, in: Capsule())
                }
                Spacer()
                if let context, context.count > 1 {
                    Text("\(context.position) of \(context.count)")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(FlotillaColors.textTertiary)
                }
            }
            content
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        .disabled(context.map { !$0.isActionable } ?? false)
        .opacity(context.map { $0.isActionable ? 1 : FlotillaStateOpacity.disabled + 0.25 } ?? 1)
    }
}

/// A card someone else resolved, briefly shown before it becomes a transcript entry.
private struct ResolutionNotice: View {
    let resolution: PendingInteraction.Resolution

    var body: some View {
        Label(text, systemImage: systemImage)
            .font(.subheadline.weight(.medium))
            .foregroundStyle(FlotillaColors.textPrimary)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 14)
            .glassEffect(.regular, in: Capsule())
            .sensoryFeedback(.warning, trigger: resolution == .alreadyAnswered)
            .accessibilityIdentifier("ResolutionNotice")
    }

    private var text: String {
        switch resolution {
        case .answeredOnMac(let outcome): "Answered on Mac · \(outcome)"
        case .alreadyAnswered: "Already answered on Mac"
        }
    }

    private var systemImage: String {
        switch resolution {
        case .answeredOnMac: "desktopcomputer"
        case .alreadyAnswered: "checkmark.circle"
        }
    }
}

private struct PromptComposer: View {
    let session: CompanionSession
    let isStopping: Bool
    let isActionable: Bool

    @Environment(CompanionStore.self) private var store
    @State private var text = ""
    @FocusState private var isFocused: Bool

    var body: some View {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        // Stop sits where Send is while the agent works and there's nothing to send.
        let showsStop = trimmed.isEmpty && (session.status == .working || isStopping)

        HStack(alignment: .bottom, spacing: 8) {
            TextField(placeholder, text: $text, axis: .vertical)
                .lineLimit(1...6)
                .focused($isFocused)
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .accessibilityIdentifier("Composer.TextField")

            Group {
                if showsStop {
                    Button {
                        Task { await store.stop(session.id) }
                    } label: {
                        if isStopping {
                            ProgressView().controlSize(.small)
                        } else {
                            Image(systemName: "stop.fill")
                        }
                    }
                    .accessibilityLabel(isStopping ? "Stopping" : "Stop")
                    .accessibilityIdentifier("Composer.Stop")
                    .disabled(isStopping)
                    .buttonStyle(.glass)
                    .foregroundStyle(FlotillaColors.textPrimary)
                } else {
                    Button {
                        let prompt = trimmed
                        text = ""
                        Task { await store.sendPrompt(prompt, to: session.id) }
                    } label: {
                        Image(systemName: "arrow.up")
                    }
                    .accessibilityLabel("Send")
                    .accessibilityIdentifier("Composer.Send")
                    .disabled(trimmed.isEmpty)
                    .tint(FlotillaColors.accent)
                }
            }
            .font(.body.weight(.semibold))
            .buttonStyle(.glassProminent)
            .buttonBorderShape(.circle)
            .controlSize(.large)
            .padding(4)
        }
        .glassEffect(.regular.interactive(), in: RoundedRectangle(cornerRadius: 24, style: .continuous))
        .disabled(!isActionable)
    }

    private var placeholder: String {
        if !isActionable { return "Mac unreachable" }
        return session.status == .working ? "Queue a message" : "Message \(session.agent.displayName)"
    }
}

private struct CrashedCard: View {
    let sessionID: CompanionSession.ID
    let reason: String?
    let isActionable: Bool
    @Environment(CompanionStore.self) private var store

    var body: some View {
        CardContainer(context: nil, title: "Session crashed", systemImage: "xmark.octagon.fill", tint: FlotillaColors.statusCrashed) {
            if let reason {
                Text(reason)
                    .font(.subheadline)
                    .foregroundStyle(FlotillaColors.textSecondary)
            }
            Button {
                Task { await store.restart(sessionID) }
            } label: {
                Text("Restart").frame(maxWidth: .infinity)
            }
            .buttonStyle(.glassProminent)
            .tint(FlotillaColors.accent)
            .controlSize(.large)
            .disabled(!isActionable)
        }
    }
}

private struct NeedsTerminalCard: View {
    let dialogTitle: String

    /// Designed in for the later terminal fallback; the prototype has no terminal.
    private static let showsOpenTerminal = false

    var body: some View {
        CardContainer(context: nil, title: "Needs your Mac's terminal", systemImage: "desktopcomputer") {
            Text(dialogTitle)
                .font(.headline)
                .foregroundStyle(FlotillaColors.textPrimary)
            Text("This dialog can only be answered in the terminal on your Mac. The session continues once it's answered there.")
                .font(.footnote)
                .foregroundStyle(FlotillaColors.textSecondary)
            if Self.showsOpenTerminal {
                Button("Open Terminal") {}
                    .buttonStyle(.bordered)
            }
        }
    }
}

private struct ReviewChangesCard: View {
    let sessionID: CompanionSession.ID
    let stat: DiffStat
    @Environment(CompanionStore.self) private var store

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(FlotillaColors.statusReady)
            VStack(alignment: .leading, spacing: 1) {
                Text("Ready for review")
                    .font(.subheadline.weight(.semibold))
                Text(stat.compactSummary)
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(FlotillaColors.textSecondary)
            }
            Spacer()
            Button("Review Changes") {
                store.acknowledgeReview(sessionID)
                store.path.append(.diff(sessionID, commitHash: nil, focusPath: nil))
            }
            .buttonStyle(.glass)
            .controlSize(.small)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }
}

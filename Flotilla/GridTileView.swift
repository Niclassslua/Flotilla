import SwiftUI
import SessionKit
import DesignSystem

struct GridTileView: View {
    let session: Session
    let store: AppStore
    let terminalManager: TerminalManager
    let isActive: Bool
    let onActivate: () -> Void
    let onOpenSession: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Text(session.title)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(FlotillaColors().statusReady)
                    .lineLimit(1)

                Text("/")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)

                HStack(spacing: 4) {
                    ProviderLogo(agent: session.agent)
                        .frame(width: 11, height: 11)
                    Text(session.agent.displayName)
                        .font(.caption2.monospaced())
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                Spacer()
                HStack(spacing: 4) {
                    StatusBadge(session.status, variant: .compact)
                    Text(StatusPresentation.label(for: session.status))
                        .font(.caption2.weight(.medium))
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(StatusPresentation.label(for: session.status))
                .accessibilityIdentifier("GridTile-\(session.title)-Status")

                Button(action: onOpenSession) {
                    Image(systemName: "arrow.up.left.and.arrow.down.right")
                        .font(.system(size: 11, weight: .medium))
                        .frame(width: 22, height: 22)
                }
                .buttonStyle(.plain)
                .help("Focus on this session")
                .accessibilityIdentifier("GridTile-\(session.title)-FocusButton")
            }
            .padding(.horizontal, 10)
            .frame(height: 34)
            .background(FlotillaColors().surface)
            .contentShape(Rectangle())
            .onTapGesture(perform: onActivate)

            Divider()

            if let process = store.process(for: session.id) {
                ZStack {
                    TerminalHostView(
                        controller: terminalManager.controller(
                            for: session,
                            process: process,
                            scrollback: store.scrollback(for: session.id),
                            outputHandler: { [weak store] data in
                                store?.appendTerminalOutput(data, toSessionID: session.id)
                            },
                            // See ContentView.terminal(for:) — keystrokes
                            // are not evidence the agent is working.
                            inputHandler: {}
                        ),
                        presentation: .grid,
                        isFocused: isActive
                    )
                    .id(process.id)

                    if !isActive {
                        Color.clear
                            .contentShape(Rectangle())
                            .onTapGesture(perform: onActivate)
                            .accessibilityHidden(true)
                    }
                }
                .background(FlotillaColors().terminalCanvas)
            } else {
                ContentUnavailableView(
                    "Agent Stopped",
                    systemImage: "exclamationmark.terminal",
                    description: Text("Open this session to restart it.")
                )
            }
        }
        .background(FlotillaColors().terminalCanvas)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(
                    isActive
                        ? FlotillaColors().accent.opacity(0.75)
                        : session.status == .waitingForInput
                        ? FlotillaColors().statusWaitingForInput.opacity(0.8)
                        : FlotillaColors().separator.opacity(0.75),
                    lineWidth: isActive || session.status == .waitingForInput ? 1.5 : 1
                )
        }
    }
}
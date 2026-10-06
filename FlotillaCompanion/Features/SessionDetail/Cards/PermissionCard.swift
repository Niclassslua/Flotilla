import SwiftUI
import DesignSystem
import CompanionKit

struct PermissionCard: View {
    let context: CardContext
    let request: PermissionRequest

    @Environment(CompanionStore.self) private var store
    @State private var noteMode: NoteMode?
    @State private var note = ""
    @State private var isSending = false
    @State private var denyCount = 0
    @FocusState private var isNoteFocused: Bool

    enum NoteMode {
        case allow
        case deny
    }

    var body: some View {
        CardContainer(context: context, title: "Permission", systemImage: "lock.open.fill") {
            VStack(alignment: .leading, spacing: 6) {
                Text(request.tool)
                    .font(.headline)
                    .foregroundStyle(FlotillaColors.textPrimary)
                Text(request.detail ?? request.summary)
                    .font(.callout.monospaced())
                    .foregroundStyle(FlotillaColors.textPrimary)
                    .lineLimit(6)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(10)
                    .background(FlotillaColors.surfaceElevated, in: RoundedRectangle(cornerRadius: FlotillaRadius.card, style: .continuous))
                if request.detail != nil, request.detail != request.summary {
                    Text("Target: \(request.summary)")
                        .font(.caption)
                        .foregroundStyle(FlotillaColors.textSecondary)
                }
                Text(scopeCaption)
                    .font(.caption)
                    .foregroundStyle(FlotillaColors.textSecondary)
                    .accessibilityIdentifier("PermissionCard.Scope")
            }

            if let noteMode {
                noteEditor(noteMode)
            } else {
                actions
            }
        }
        .sensoryFeedback(trigger: isSending) { _, sending in sending ? .success : nil }
        .modifier(HapticsOnChange(value: denyCount, feedback: .warning))
    }

    /// What Allow covers versus what the broader Always-Allow option (when
    /// offered) would remember, so the decision's scope sits next to it
    /// instead of only inside the overflow menu.
    private var scopeCaption: String {
        guard request.allowsAlwaysAllow != false else {
            return "This tool only supports one-time approval here — there's no broader option to grant."
        }
        let label = context.capabilities.alwaysAllowLabel(for: request)
        return "Allow approves this one request. \(label.prefix(1).uppercased() + label.dropFirst()) remembers the choice — see More."
    }

    private var actions: some View {
        HStack(spacing: 8) {
            Button { denyCount += 1; send(.deny) } label: {
                Text("Deny").frame(maxWidth: .infinity, minHeight: 50)
            }
            .companionGlassButtonStyle()
            .accessibilityIdentifier("PermissionCard.Deny")

            Button { send(.allow) } label: {
                Text("Allow").frame(maxWidth: .infinity, minHeight: 50)
            }
            .companionGlassButtonStyle(prominent: true)
            .tint(FlotillaColors.accent)
            .accessibilityIdentifier("PermissionCard.Allow")

            moreMenu(expandsToFill: false, matchesRowHeight: true)
        }
        .controlSize(.large)
        .disabled(isSending)
    }

    /// `expandsToFill` splits the row width evenly with its neighbor;
    /// otherwise it hugs its content. `matchesRowHeight` sets minHeight to
    /// 50 either way, so it never reads shorter than buttons beside it.
    private func moreMenu(expandsToFill: Bool, matchesRowHeight: Bool = false) -> some View {
        Menu {
            if request.allowsAlwaysAllow != false {
                Button(context.capabilities.alwaysAllowLabel(for: request), systemImage: "checkmark.seal") { send(.alwaysAllow) }
            }
            Button("Allow with Note…", systemImage: "text.bubble") { beginNote(.allow) }
            Button("Deny with Note…", systemImage: "text.bubble") { beginNote(.deny) }
            if request.allowsDenyAndStop != false {
                Divider()
                Button("Deny and Stop", systemImage: "stop.circle", role: .destructive) { send(.denyAndStop) }
            }
        } label: {
            Image(systemName: "ellipsis")
                .frame(width: 22)
                .frame(
                    maxWidth: expandsToFill ? .infinity : nil,
                    minHeight: (expandsToFill || matchesRowHeight) ? 50 : nil
                )
        }
        .companionGlassButtonStyle()
        .accessibilityLabel("More")
        .accessibilityIdentifier("PermissionCard.More")
    }

    private func noteEditor(_ mode: NoteMode) -> some View {
        VStack(spacing: 8) {
            TextField(mode == .allow ? "Note for the agent" : "Why not? Tell the agent what to do instead", text: $note, axis: .vertical)
                .lineLimit(1...4)
                .focused($isNoteFocused)
                .padding(10)
                .background(FlotillaColors.surface, in: RoundedRectangle(cornerRadius: FlotillaRadius.card, style: .continuous))
            HStack(spacing: 8) {
                Button {
                    noteMode = nil
                    note = ""
                } label: {
                    Text("Cancel").frame(maxWidth: .infinity)
                }
                .companionGlassButtonStyle()

                Button {
                    let text = note.trimmingCharacters(in: .whitespacesAndNewlines)
                    send(mode == .allow ? .allowWithNote(text) : .denyWithNote(text))
                } label: {
                    Text(mode == .allow ? "Allow" : "Deny").frame(maxWidth: .infinity)
                }
                .companionGlassButtonStyle(prominent: true)
                .tint(mode == .allow ? FlotillaColors.accent : FlotillaColors.textSecondary)
                .disabled(note.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            .controlSize(.large)
        }
    }

    private func beginNote(_ mode: NoteMode) {
        withAnimation(.snappy) { noteMode = mode }
        isNoteFocused = true
    }

    private func send(_ answer: InteractionAnswer) {
        isSending = true
        Task {
            _ = await store.answer(context.interaction.id, in: context.sessionID, with: answer)
            isSending = false
        }
    }
}

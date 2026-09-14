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
            }

            if let noteMode {
                noteEditor(noteMode)
            } else {
                actions
            }
        }
        .sensoryFeedback(trigger: isSending) { _, sending in sending ? .success : nil }
    }

    private var actions: some View {
        HStack(spacing: 8) {
            Button { send(.deny) } label: {
                Text("Deny").frame(maxWidth: .infinity)
            }
            .buttonStyle(.glass)
            .accessibilityIdentifier("PermissionCard.Deny")

            Button { send(.allow) } label: {
                Text("Allow").frame(maxWidth: .infinity)
            }
            .buttonStyle(.glassProminent)
            .tint(FlotillaColors.accent)
            .accessibilityIdentifier("PermissionCard.Allow")

            Menu {
                Button(context.capabilities.alwaysAllowLabel(for: request), systemImage: "checkmark.seal") { send(.alwaysAllow) }
                Button("Allow with Note…", systemImage: "text.bubble") { beginNote(.allow) }
                Button("Deny with Note…", systemImage: "text.bubble") { beginNote(.deny) }
                Divider()
                Button("Deny and Stop", systemImage: "stop.circle", role: .destructive) { send(.denyAndStop) }
            } label: {
                Image(systemName: "ellipsis")
                    .frame(width: 22)
            }
            .buttonStyle(.glass)
            .accessibilityLabel("More")
            .accessibilityIdentifier("PermissionCard.More")
        }
        .controlSize(.large)
        .disabled(isSending)
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
                .buttonStyle(.glass)

                Button {
                    let text = note.trimmingCharacters(in: .whitespacesAndNewlines)
                    send(mode == .allow ? .allowWithNote(text) : .denyWithNote(text))
                } label: {
                    Text(mode == .allow ? "Allow" : "Deny").frame(maxWidth: .infinity)
                }
                .buttonStyle(.glassProminent)
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

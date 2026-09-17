import SwiftUI
import DesignSystem
import Textual
import CompanionKit

struct PlanCard: View {
    let context: CardContext
    let plan: PlanProposal

    @State private var isReading = false
    @State private var isRevising = false

    var body: some View {
        CardContainer(context: context, title: "Plan ready", systemImage: "list.clipboard.fill") {
            Text(plan.title)
                .font(.headline)
                .foregroundStyle(FlotillaColors.textPrimary)
            Text(preview)
                .font(.subheadline)
                .foregroundStyle(FlotillaColors.textSecondary)
                .lineLimit(3)

            Button("Read Plan", systemImage: "doc.text.magnifyingglass") { isReading = true }
                .font(.subheadline.weight(.medium))
                .buttonStyle(.plain)
                .foregroundStyle(FlotillaColors.statusReady)

            PlanActions(context: context, isRevising: $isRevising)
        }
        .sheet(isPresented: $isReading) {
            PlanReader(context: context, plan: plan)
        }
    }

    /// The first prose paragraph as plain text — no headings, list items, or
    /// inline Markdown markers.
    private var preview: String {
        let paragraph = plan.markdown
            .split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .first { line in
                !line.isEmpty && !line.hasPrefix("#") && !line.hasPrefix("-") && !line.hasPrefix("*")
                    && line.first?.isNumber != true
            } ?? ""
        let attributed = try? AttributedString(markdown: paragraph)
        return attributed.map { String($0.characters) } ?? paragraph
    }
}

/// Approve (split by mode where the provider offers one) and Revise.
private struct PlanActions: View {
    let context: CardContext
    @Binding var isRevising: Bool
    var onAnswered: () -> Void = {}

    @Environment(CompanionStore.self) private var store
    @State private var revision = ""
    @State private var isSending = false

    var body: some View {
        Group {
            if isRevising {
                VStack(spacing: 8) {
                    TextField("What should change?", text: $revision, axis: .vertical)
                        .lineLimit(1...5)
                        .padding(10)
                        .background(FlotillaColors.surface, in: RoundedRectangle(cornerRadius: FlotillaRadius.card, style: .continuous))
                    HStack(spacing: 8) {
                        Button {
                            revision = ""
                            isRevising = false
                        } label: { Text("Cancel").frame(maxWidth: .infinity) }
                            .buttonStyle(.glass)
                        Button {
                            send(.revisePlan(revision.trimmingCharacters(in: .whitespacesAndNewlines)))
                        } label: {
                            Text("Send Revision").frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.glassProminent)
                        .tint(FlotillaColors.accent)
                        .disabled(revision.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                    .controlSize(.large)
                }
            } else if context.capabilities.planApprovalHasModeSplit {
                VStack(spacing: 8) {
                    Button { send(.approvePlan(.autoAccept)) } label: {
                        Text("Approve & Auto-Accept Edits")
                            .frame(maxWidth: .infinity, minHeight: 50)
                    }
                    .buttonStyle(.glassProminent)
                    .tint(FlotillaColors.accent)
                    HStack(spacing: 8) {
                        Button { send(.approvePlan(.askForEdits)) } label: {
                            Text("Approve & Ask for Edits")
                                .frame(maxWidth: .infinity, minHeight: 50)
                        }
                        .buttonStyle(.glass)
                        Button { isRevising = true } label: {
                            Text("Revise")
                                .frame(maxWidth: .infinity, minHeight: 50)
                        }
                        .buttonStyle(.glass)
                    }
                }
                .controlSize(.large)
                .disabled(isSending)
            } else {
                VStack(spacing: 8) {
                    Button { send(.approvePlan(nil)) } label: { Text("Approve").frame(maxWidth: .infinity, minHeight: 50) }
                        .buttonStyle(.glassProminent)
                        .tint(FlotillaColors.accent)
                    Button { isRevising = true } label: { Text("Revise").frame(maxWidth: .infinity, minHeight: 50) }
                        .buttonStyle(.glass)
                }
                .controlSize(.large)
                .disabled(isSending)
            }
        }
        .onAppear { revision = store.planRevisionDraft(for: context.sessionID) }
        .onChange(of: revision) { _, newValue in store.savePlanRevisionDraft(newValue, for: context.sessionID) }
    }

    private func send(_ answer: InteractionAnswer) {
        isSending = true
        onAnswered()
        Task {
            let outcome = await store.answer(context.interaction.id, in: context.sessionID, with: answer)
            if outcome != nil {
                store.savePlanRevisionDraft("", for: context.sessionID)
                revision = ""
            }
            isSending = false
        }
    }
}

private struct PlanReader: View {
    let context: CardContext
    let plan: PlanProposal

    @Environment(\.dismiss) private var dismiss
    @State private var isRevising = false

    var body: some View {
        NavigationStack {
            ScrollView {
                StructuredText(markdown: plan.markdown)
                    .textual.structuredTextStyle(.gitHub)
                    .textual.textSelection(.enabled)
                    .foregroundStyle(FlotillaColors.textPrimary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(16)
            }
            .background(FlotillaColors.canvas)
            .safeAreaInset(edge: .bottom) {
                PlanActions(context: context, isRevising: $isRevising, onAnswered: { dismiss() })
                    .padding(14)
                    .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
                    .padding(.horizontal, 12)
                    .disabled(!context.isActionable)
            }
            .navigationTitle(plan.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close", systemImage: "xmark") { dismiss() }
                }
            }
        }
    }
}

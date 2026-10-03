import SwiftUI
import SessionKit
import DesignSystem

struct DeleteSessionSheet: View {
    let session: Session
    /// Whether the session still owns a live PTY. Deleting one stops the agent
    /// mid-work, which nothing here can undo, so it is called out rather than
    /// left for the user to remember.
    var isRunning: Bool = false
    /// Pre-selected worktree choice from Settings ▸ Git & Worktrees. The sheet
    /// still always confirms; this only seeds the initial selection.
    var defaultDeleteWorktree: Bool = false
    let onCancel: () -> Void
    let onDelete: (Bool) -> Void

    @State private var deleteWorktree: Bool

    init(
        session: Session,
        isRunning: Bool = false,
        defaultDeleteWorktree: Bool = false,
        onCancel: @escaping () -> Void,
        onDelete: @escaping (Bool) -> Void
    ) {
        self.session = session
        self.isRunning = isRunning
        self.defaultDeleteWorktree = defaultDeleteWorktree
        self.onCancel = onCancel
        self.onDelete = onDelete
        _deleteWorktree = State(initialValue: defaultDeleteWorktree)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: FlotillaSpacing.xLarge) {
            header

            if isRunning {
                Label(
                    "This session's agent is still running. Deleting it stops the process immediately.",
                    systemImage: "exclamationmark.triangle.fill"
                )
                .font(.callout)
                .foregroundStyle(FlotillaColors.statusWaitingForInput)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityIdentifier("DeleteSessionDialog.RunningWarning")
            }

            if let worktree = session.worktree {
                worktreeDetails(worktree)
                worktreeChoices
            }

            Divider()

            HStack(spacing: FlotillaSpacing.small) {
                Button("Cancel", action: onCancel)
                    .buttonStyle(.bordered)
                    .keyboardShortcut(.defaultAction)
                    .accessibilityIdentifier("DeleteSessionDialog.Cancel")

                Spacer()

                Button(role: .destructive) {
                    onDelete(deleteWorktree)
                } label: {
                    Label(
                        deleteWorktree ? "Delete Session & Worktree" : "Delete Session",
                        systemImage: "trash"
                    )
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, FlotillaSpacing.large)
                    .padding(.vertical, FlotillaSpacing.small)
                    .background(FlotillaColors.danger, in: RoundedRectangle(cornerRadius: FlotillaRadius.control))
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier(deleteButtonID)
            }
            .controlSize(.large)
        }
        .padding(FlotillaSpacing.xLarge)
        .frame(width: session.worktree == nil ? 480 : 620)
    }

    private var header: some View {
        HStack(alignment: .top, spacing: FlotillaSpacing.large) {
            Image(systemName: "trash")
                .font(.system(size: 19, weight: .medium))
                .foregroundStyle(FlotillaColors.danger)
                .frame(width: 44, height: 44)
                .background(FlotillaColors.dangerSurface, in: RoundedRectangle(cornerRadius: FlotillaRadius.card))
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: FlotillaSpacing.small) {
                Text("Delete session?")
                    .font(.system(size: 25, weight: .semibold))

                Text(session.title)
                    .font(.system(size: 14, weight: .medium, design: .monospaced))
                    .foregroundStyle(.primary)
                    .fixedSize(horizontal: false, vertical: true)

                Text("Terminal history and session metadata will be permanently removed.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func worktreeDetails(_ worktree: WorktreeInfo) -> some View {
        VStack(alignment: .leading, spacing: FlotillaSpacing.xSmall) {
            HStack {
                Text("LINKED WORKTREE")
                    .font(.caption2.weight(.semibold))
                    .tracking(1.2)
                    .foregroundStyle(.secondary)
                Spacer()
                GitBranchLabel(worktree.branchName, size: 12)
                    .font(.caption)
            }

            Text(worktree.worktreePath.path)
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .textSelection(.enabled)
        }
    }

    private var worktreeChoices: some View {
        VStack(alignment: .leading, spacing: FlotillaSpacing.small) {
            Text("What happens to the worktree?")
                .font(.callout.weight(.semibold))

            HStack(alignment: .top, spacing: FlotillaSpacing.small) {
                worktreeChoice(
                    title: "Keep worktree",
                    detail: "Its files and branch stay on disk.",
                    symbol: "folder",
                    isSelected: !deleteWorktree,
                    isDestructive: false,
                    axID: "DeleteSessionDialog.KeepWorktreeOption"
                ) { deleteWorktree = false }

                worktreeChoice(
                    title: "Remove worktree",
                    detail: "Remove its files. Branch cleanup follows Git settings.",
                    symbol: "trash",
                    isSelected: deleteWorktree,
                    isDestructive: true,
                    axID: "DeleteSessionDialog.RemoveWorktreeOption"
                ) { deleteWorktree = true }
            }
        }
    }

    private func worktreeChoice(
        title: String,
        detail: String,
        symbol: String,
        isSelected: Bool,
        isDestructive: Bool,
        axID: String,
        action: @escaping () -> Void
    ) -> some View {
        let accent = isDestructive ? FlotillaColors.danger : FlotillaColors.accent

        return Button(action: action) {
            VStack(alignment: .leading, spacing: FlotillaSpacing.medium) {
                HStack {
                    Image(systemName: symbol)
                        .font(.system(size: 18))
                        .foregroundStyle(isSelected ? accent : .secondary)
                    Spacer()
                    Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                        .foregroundStyle(isSelected ? accent : .secondary)
                }

                VStack(alignment: .leading, spacing: FlotillaSpacing.xSmall) {
                    Text(title)
                        .font(.callout.weight(.semibold))
                        .foregroundStyle(.primary)
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity, minHeight: 72, alignment: .topLeading)
            .padding(FlotillaSpacing.medium)
            .background(
                isSelected ? accent.opacity(0.09) : Color(nsColor: .controlBackgroundColor),
                in: RoundedRectangle(cornerRadius: FlotillaRadius.card)
            )
            .overlay {
                RoundedRectangle(cornerRadius: FlotillaRadius.card)
                    .strokeBorder(isSelected ? accent.opacity(0.75) : FlotillaColors.separator, lineWidth: 1)
            }
            .contentShape(RoundedRectangle(cornerRadius: FlotillaRadius.card))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(title). \(detail)")
        .accessibilityValue(isSelected ? "Selected" : "Not selected")
        .accessibilityIdentifier(axID)
    }

    private var deleteButtonID: String {
        if session.worktree == nil { return "DeleteSessionDialog.DeleteSessionOnly" }
        return deleteWorktree
            ? "DeleteSessionDialog.DeleteWithWorktree"
            : "DeleteSessionDialog.KeepWorktreeDeleteSession"
    }
}

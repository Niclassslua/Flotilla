import SwiftUI
import SessionKit
import DesignSystem

struct DeleteSessionSheet: View {
    let session: Session
    /// Whether the session still owns a live PTY. Deleting one stops the agent
    /// mid-work, which nothing here can undo, so it is called out rather than
    /// left for the user to remember.
    var isRunning: Bool = false
    let onCancel: () -> Void
    let onDelete: (Bool) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack(alignment: .top, spacing: 14) {
                Image(systemName: "trash.circle.fill")
                    .font(.system(size: 34))
                    .foregroundStyle(.red)
                    .symbolRenderingMode(.hierarchical)
                VStack(alignment: .leading, spacing: 5) {
                    Text("Delete “\(session.title)”?")
                        .font(.title3.weight(.semibold))
                    Text(explanation)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

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
                VStack(alignment: .leading, spacing: 4) {
                    GitBranchLabel(worktree.branchName, size: 12)
                    Text(worktree.worktreePath.path)
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 9))
            }

            // Stacked full-width rather than a row: at this sheet's width three
            // buttons side by side truncated "Keep Worktree, Delete Session" to
            // "Keep Worktree, Delete Ses…" — the one label that distinguishes
            // the two destructive outcomes. Return belongs to Cancel; deleting
            // a branch on a keypress has no undo.
            VStack(spacing: 8) {
                if session.worktree != nil {
                    destructiveButton(
                        "Delete Session & Worktree",
                        axID: "DeleteSessionDialog.DeleteWithWorktree"
                    ) { onDelete(true) }

                    // `role: .destructive` renders as an ordinary button outside
                    // a confirmation dialog, so the outcomes are separated by
                    // tint as well as by label: only the branch-destroying path
                    // is red.
                    Button("Keep Worktree, Delete Session Only") { onDelete(false) }
                        .buttonStyle(.bordered)
                        .controlSize(.large)
                        .frame(maxWidth: .infinity)
                        .accessibilityIdentifier("DeleteSessionDialog.KeepWorktreeDeleteSession")
                } else {
                    destructiveButton(
                        "Delete Session",
                        axID: "DeleteSessionDialog.DeleteSessionOnly"
                    ) { onDelete(false) }
                }

                Button("Cancel", action: onCancel)
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .frame(maxWidth: .infinity)
                    .keyboardShortcut(.defaultAction)
                    .accessibilityIdentifier("DeleteSessionDialog.Cancel")
            }
        }
        .padding(24)
        .frame(width: 500)
    }

    private func destructiveButton(
        _ title: String,
        axID: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(title, role: .destructive, action: action)
            .buttonStyle(.bordered)
            .controlSize(.large)
            .tint(.red)
            .frame(maxWidth: .infinity)
            .accessibilityIdentifier(axID)
    }

    private var explanation: String {
        session.worktree == nil
            ? "Terminal history and session metadata will be permanently removed."
            : "Remove only Flotilla's session record, or also clean up its isolated worktree and branch from Git."
    }
}

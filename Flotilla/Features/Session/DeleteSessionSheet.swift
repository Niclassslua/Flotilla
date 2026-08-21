import SwiftUI
import SessionKit

struct DeleteSessionSheet: View {
    let session: Session
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
                    Text("Delete “\(session.title)”? ")
                        .font(.title3.weight(.semibold))
                    Text(explanation)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            if let worktree = session.worktree {
                VStack(alignment: .leading, spacing: 4) {
                    Label(worktree.branchName, systemImage: "arrow.triangle.branch")
                    Text(worktree.worktreePath.path)
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 9))
            }

            HStack {
                Button("Cancel", action: onCancel)
                    .keyboardShortcut(.cancelAction)
                    .accessibilityIdentifier("DeleteSessionDialog.Cancel")
                Spacer()
                if session.worktree != nil {
                    Button("Keep Worktree, Delete Session") { onDelete(false) }
                        .accessibilityIdentifier("DeleteSessionDialog.KeepWorktreeDeleteSession")
                }
                Button(session.worktree == nil ? "Delete Session" : "Delete Session & Worktree", role: .destructive) {
                    onDelete(session.worktree != nil)
                }
                .keyboardShortcut(.defaultAction)
                .accessibilityIdentifier(
                    session.worktree == nil
                        ? "DeleteSessionDialog.DeleteSessionOnly"
                        : "DeleteSessionDialog.DeleteWithWorktree"
                )
            }
        }
        .padding(24)
        .frame(width: 500)
    }

    private var explanation: String {
        session.worktree == nil
            ? "Terminal history and session metadata will be permanently removed."
            : "Remove only Flotilla's session record, or also clean up its isolated worktree and branch from Git."
    }
}
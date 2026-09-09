import SwiftUI
import SessionKit
import DesignSystem

/// One recorded comment, shown under the line or file it is attached to.
///
/// A comment that has been delivered is dimmed rather than removed: the agent
/// is acting on it, and seeing it in place is how a second pass tells what was
/// already asked for from what is new.
struct ReviewCommentBubble: View {
    let comment: ReviewComment
    let onEdit: () -> Void
    let onDelete: () -> Void

    @State private var isHovering = false
    @FocusState private var focusedAction: Action?

    private enum Action: Hashable {
        case edit
        case delete
    }

    var body: some View {
        HStack(alignment: .top, spacing: FlotillaSpacing.small) {
            Image(systemName: comment.isSent ? "checkmark.bubble" : "bubble.left")
                .font(.system(size: FlotillaIconSize.xSmall))
                .foregroundStyle(comment.isSent ? FlotillaColors.textTertiary : FlotillaColors.accent)
                .padding(.top, 1)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 2) {
                Text(comment.body)
                    .font(FlotillaTypography.caption)
                    .foregroundStyle(comment.isSent ? FlotillaColors.textTertiary : FlotillaColors.textPrimary)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)

                if comment.isSent {
                    Text("Sent")
                        .font(FlotillaTypography.caption3)
                        .foregroundStyle(FlotillaColors.textTertiary)
                }
            }

            actions
                .opacity(isHovering || focusedAction != nil ? 1 : 0)
        }
        .padding(.horizontal, FlotillaSpacing.small)
        .padding(.vertical, FlotillaSpacing.small)
        .background(
            FlotillaColors.surfaceElevated,
            in: RoundedRectangle(cornerRadius: FlotillaRadius.control, style: .continuous)
        )
        .overlay(alignment: .leading) {
            // A left rule ties the bubble to the line above it, which matters
            // most in Side by Side where the bubble spans both columns.
            Rectangle()
                .fill(comment.isSent ? FlotillaColors.separator : FlotillaColors.accent)
                .frame(width: FlotillaBorderWidth.thick)
        }
        .clipShape(RoundedRectangle(cornerRadius: FlotillaRadius.control, style: .continuous))
        .onHover { isHovering = $0 }
    }

    private var actions: some View {
        HStack(spacing: FlotillaSpacing.xSmall) {
            Button(action: onEdit) {
                Image(systemName: "pencil")
            }
            .focused($focusedAction, equals: .edit)
            .help("Edit comment")
            .accessibilityLabel("Edit comment")

            Button(action: onDelete) {
                Image(systemName: "trash")
            }
            .focused($focusedAction, equals: .delete)
            .help("Delete comment")
            .accessibilityLabel("Delete comment")
        }
        .font(.system(size: FlotillaIconSize.xSmall))
        .foregroundStyle(FlotillaColors.textSecondary)
        .buttonStyle(.plain)
    }
}

/// Composes a new comment, or edits an existing one.
struct ReviewCommentEditor: View {
    let title: String
    @Binding var text: String
    let onSubmit: () -> Void
    let onCancel: () -> Void

    @FocusState private var isFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: FlotillaSpacing.small) {
            Text(title)
                .font(FlotillaTypography.caption2.weight(.medium))
                .foregroundStyle(FlotillaColors.textTertiary)

            TextEditor(text: $text)
                .font(FlotillaTypography.caption)
                .scrollContentBackground(.hidden)
                .focused($isFocused)
                .frame(minHeight: 56, maxHeight: 120)
                .padding(FlotillaSpacing.xSmall)
                .background(
                    FlotillaColors.surface,
                    in: RoundedRectangle(cornerRadius: FlotillaRadius.control, style: .continuous)
                )
                .overlay {
                    RoundedRectangle(cornerRadius: FlotillaRadius.control, style: .continuous)
                        .strokeBorder(FlotillaColors.separator, lineWidth: FlotillaBorderWidth.hairline)
                }
                .accessibilityIdentifier(AXID.reviewCommentEditor.rawValue)

            HStack(spacing: FlotillaSpacing.small) {
                Spacer(minLength: 0)
                Button("Cancel", action: onCancel)
                    .keyboardShortcut(.cancelAction)
                    .accessibilityIdentifier(AXID.reviewCommentCancel.rawValue)
                Button("Add Comment", action: onSubmit)
                    .keyboardShortcut(.return, modifiers: .command)
                    .buttonStyle(.borderedProminent)
                    .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .accessibilityIdentifier(AXID.reviewCommentSubmit.rawValue)
            }
            .font(FlotillaTypography.caption)
        }
        .padding(FlotillaSpacing.small)
        .background(
            FlotillaColors.surfaceElevated,
            in: RoundedRectangle(cornerRadius: FlotillaRadius.control, style: .continuous)
        )
        .onAppear { isFocused = true }
    }
}

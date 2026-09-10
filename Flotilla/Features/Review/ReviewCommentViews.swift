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
///
/// One card: a borderless field on top, a hairline, then an action row that
/// also carries the context and the submit shortcut. The whole card's border
/// tracks focus so it reads as the active element in a busy diff.
struct ReviewCommentEditor: View {
    let title: String
    @Binding var text: String
    let onSubmit: () -> Void
    let onCancel: () -> Void

    @FocusState private var isFocused: Bool

    private var canSubmit: Bool {
        !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        VStack(spacing: 0) {
            field
            Divider()
            actionRow
        }
        .background(FlotillaColors.surface)
        .clipShape(RoundedRectangle(cornerRadius: FlotillaRadius.card, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: FlotillaRadius.card, style: .continuous)
                .strokeBorder(
                    isFocused ? FlotillaColors.accent : FlotillaColors.separator,
                    lineWidth: isFocused ? 1.5 : FlotillaBorderWidth.hairline
                )
        }
        .animation(FlotillaMotion.fast.curve, value: isFocused)
        .onAppear { isFocused = true }
    }

    // MARK: - Field

    private var field: some View {
        ZStack(alignment: .topLeading) {
            if text.isEmpty {
                Text("Leave a comment")
                    .font(FlotillaTypography.caption)
                    .foregroundStyle(FlotillaColors.textTertiary)
                    .padding(.leading, 5)
                    .padding(.top, 8)
                    .allowsHitTesting(false)
            }

            TextEditor(text: $text)
                .font(FlotillaTypography.caption)
                .foregroundStyle(FlotillaColors.textPrimary)
                .scrollContentBackground(.hidden)
                .focused($isFocused)
                .accessibilityIdentifier(AXID.reviewCommentEditor.rawValue)
        }
        .padding(.horizontal, FlotillaSpacing.small)
        .padding(.vertical, FlotillaSpacing.xSmall)
        .frame(minHeight: 62, maxHeight: 148)
    }

    // MARK: - Action row

    private var actionRow: some View {
        HStack(spacing: FlotillaSpacing.small) {
            Label(title, systemImage: "text.bubble")
                .labelStyle(.titleAndIcon)
                .font(FlotillaTypography.caption2)
                .foregroundStyle(FlotillaColors.textTertiary)
                .lineLimit(1)
                .truncationMode(.middle)

            Spacer(minLength: FlotillaSpacing.small)

            Text("⌘↩")
                .font(FlotillaTypography.caption2.monospaced())
                .foregroundStyle(FlotillaColors.textTertiary)
                .opacity(canSubmit ? 1 : 0)

            Button("Cancel", action: onCancel)
                .buttonStyle(.plain)
                .font(FlotillaTypography.caption.weight(.medium))
                .foregroundStyle(FlotillaColors.textSecondary)
                .keyboardShortcut(.cancelAction)
                .accessibilityIdentifier(AXID.reviewCommentCancel.rawValue)

            Button(action: onSubmit) {
                Text("Add comment")
                    .font(FlotillaTypography.caption.weight(.semibold))
                    .foregroundStyle(FlotillaColors.accentContent)
                    .padding(.horizontal, FlotillaSpacing.medium)
                    .padding(.vertical, 5)
                    .background(
                        canSubmit ? FlotillaColors.accent : FlotillaColors.accent.opacity(0.4),
                        in: RoundedRectangle(cornerRadius: FlotillaRadius.control, style: .continuous)
                    )
            }
            .buttonStyle(.plain)
            .disabled(!canSubmit)
            .keyboardShortcut(.return, modifiers: .command)
            .accessibilityIdentifier(AXID.reviewCommentSubmit.rawValue)
        }
        .padding(.horizontal, FlotillaSpacing.medium)
        .padding(.vertical, FlotillaSpacing.small)
        .background(FlotillaColors.surfaceElevated)
    }
}

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
/// Frameless "command bar": a caps context label, a single line that grows to
/// a few, and just an underline that turns accent and glows on focus. The
/// Cancel / Comment buttons stay hidden until there is focus or something to
/// send.
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
        VStack(alignment: .leading, spacing: FlotillaSpacing.xSmall) {
            Text(title.uppercased())
                .font(.system(size: 9, weight: .semibold))
                .tracking(FlotillaTypography.Tracking.loose)
                .foregroundStyle(FlotillaColors.textTertiary)

            HStack(alignment: .center, spacing: FlotillaSpacing.small) {
                Image(systemName: "text.append")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(isFocused ? FlotillaColors.accent : FlotillaColors.textTertiary)

                TextField("Add a comment — ⌘↩ to save, esc to dismiss", text: $text, axis: .vertical)
                    .textFieldStyle(.plain)
                    .lineLimit(1...6)
                    .font(FlotillaTypography.caption)
                    .foregroundStyle(FlotillaColors.textPrimary)
                    .focused($isFocused)
                    .accessibilityIdentifier(AXID.reviewCommentEditor.rawValue)
            }
            .padding(.vertical, FlotillaSpacing.small)
            .overlay(alignment: .bottom) {
                Rectangle()
                    .fill(isFocused ? FlotillaColors.accent : FlotillaColors.separator)
                    .frame(height: isFocused ? 1.5 : FlotillaBorderWidth.hairline)
                    .shadow(color: isFocused ? FlotillaColors.accent.opacity(0.55) : .clear, radius: 4, y: 1)
            }

            HStack(spacing: FlotillaSpacing.medium) {
                Spacer(minLength: 0)
                Button("Cancel", action: onCancel)
                    .buttonStyle(.plain)
                    .font(FlotillaTypography.caption2)
                    .foregroundStyle(FlotillaColors.textTertiary)
                    .keyboardShortcut(.cancelAction)
                    .accessibilityIdentifier(AXID.reviewCommentCancel.rawValue)
                Button("Comment", action: onSubmit)
                    .buttonStyle(.plain)
                    .font(FlotillaTypography.caption2.weight(.semibold))
                    .foregroundStyle(canSubmit ? FlotillaColors.accent : FlotillaColors.textTertiary)
                    .disabled(!canSubmit)
                    .keyboardShortcut(.return, modifiers: .command)
                    .accessibilityIdentifier(AXID.reviewCommentSubmit.rawValue)
            }
            .opacity(isFocused || canSubmit ? 1 : 0)
        }
        .animation(FlotillaMotion.fast.curve, value: isFocused)
        .animation(FlotillaMotion.fast.curve, value: canSubmit)
        .onAppear { isFocused = true }
    }
}

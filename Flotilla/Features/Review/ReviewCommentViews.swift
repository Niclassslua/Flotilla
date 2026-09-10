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
/// Currently an exploration: four candidate looks, switchable live from the
/// brush menu in the top-right corner. Once one is picked this collapses to
/// that single body and ``ReviewCommentEditorVariants`` goes away.
struct ReviewCommentEditor: View {
    let title: String
    @Binding var text: String
    let onSubmit: () -> Void
    let onCancel: () -> Void

    @AppStorage(ReviewCommentEditorVariant.storageKey)
    private var variantRaw = ReviewCommentEditorVariant.default.rawValue

    private var variant: Binding<ReviewCommentEditorVariant> {
        Binding(
            get: { ReviewCommentEditorVariant(rawValue: variantRaw) ?? .default },
            set: { variantRaw = $0.rawValue }
        )
    }

    var body: some View {
        Group {
            switch variant.wrappedValue {
            case .messenger:
                ReviewCommentEditorMessenger(title: title, text: $text, onSubmit: onSubmit, onCancel: onCancel)
            case .terminal:
                ReviewCommentEditorTerminal(title: title, text: $text, onSubmit: onSubmit, onCancel: onCancel)
            case .stickyNote:
                ReviewCommentEditorStickyNote(title: title, text: $text, onSubmit: onSubmit, onCancel: onCancel)
            case .commandBar:
                ReviewCommentEditorCommandBar(title: title, text: $text, onSubmit: onSubmit, onCancel: onCancel)
            }
        }
        .padding(.top, 24)
        .overlay(alignment: .topTrailing) {
            ReviewCommentVariantMenu(selection: variant)
                .padding(.trailing, 2)
        }
    }
}

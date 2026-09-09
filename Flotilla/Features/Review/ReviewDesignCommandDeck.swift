import SwiftUI
import GitKit
import DesignSystem

/// Design 4 — Command Deck.
///
/// The dense, everything-at-a-glance option: a stats strip along the top, the
/// directory tree on the left, a tight plain diff, and a persistent action
/// bar pinned to the bottom so Send is always in reach.
struct ReviewCommandDeckLayout: View {
    @Bindable var viewModel: SessionReviewViewModel
    let branch: String?
    @Binding var design: ReviewDesign
    @Binding var draft: ReviewCommentDraft?
    @Binding var draftText: String
    let onRefresh: () -> Void
    let onSend: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            statsBar
            Divider()
            HStack(spacing: 0) {
                ReviewFileList(viewModel: viewModel)
                Divider()
                ReviewDiffPane(viewModel: viewModel, draft: $draft, draftText: $draftText, style: .commandDeck)
            }
            Divider()
            actionBar
        }
        .onAppear { viewModel.fileDisplay = .allFiles }
    }

    // MARK: - Stats bar

    private var statsBar: some View {
        HStack(spacing: FlotillaSpacing.medium) {
            VStack(alignment: .leading, spacing: 1) {
                Text(viewModel.session.title)
                    .font(FlotillaTypography.caption.weight(.semibold))
                    .foregroundStyle(FlotillaColors.textPrimary)
                    .lineLimit(1)
                if let branch {
                    Text(branch)
                        .font(FlotillaTypography.caption3.monospaced())
                        .foregroundStyle(FlotillaColors.textTertiary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            .frame(minWidth: 120, alignment: .leading)

            Divider().frame(height: 24)

            metric(value: "\(viewModel.files.count)", label: "files")
            metric(value: "+\(viewModel.totalStat.additions)", label: "added", tint: FlotillaColors.diffAdded)
            metric(value: "−\(viewModel.totalStat.deletions)", label: "removed", tint: FlotillaColors.diffRemoved)
            metric(value: "\(viewModel.comments.count)", label: "comments")

            HStack(spacing: FlotillaSpacing.small) {
                metric(value: "\(viewModel.viewedCount)/\(viewModel.files.count)", label: "viewed")
                ReviewProgressBar(viewed: viewModel.viewedCount, total: viewModel.files.count, height: 4)
                    .frame(width: 72)
            }

            Spacer(minLength: FlotillaSpacing.small)

            ReviewMiniControls(viewModel: viewModel)
            Button(action: onRefresh) {
                Image(systemName: "arrow.clockwise").font(.system(size: FlotillaIconSize.xSmall, weight: .semibold))
            }
            .buttonStyle(.plain)
            .foregroundStyle(FlotillaColors.textSecondary)
            .disabled(viewModel.isLoading)
            .accessibilityIdentifier(AXID.reviewRefresh.rawValue)
            ReviewDesignMenu(design: $design)
        }
        .padding(.horizontal, FlotillaSpacing.medium)
        .padding(.vertical, FlotillaSpacing.small)
        .background(FlotillaColors.sidebar)
    }

    private func metric(value: String, label: String, tint: Color = FlotillaColors.textPrimary) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(value)
                .font(.system(size: 13, weight: .semibold, design: .monospaced))
                .foregroundStyle(tint)
            Text(label.uppercased())
                .font(.system(size: 8, weight: .medium))
                .tracking(FlotillaTypography.Tracking.loose)
                .foregroundStyle(FlotillaColors.textTertiary)
        }
        .fixedSize()
    }

    // MARK: - Action bar

    private var actionBar: some View {
        HStack(spacing: FlotillaSpacing.medium) {
            Text(pendingSummary)
                .font(FlotillaTypography.caption2.monospaced())
                .foregroundStyle(FlotillaColors.textSecondary)
            Spacer(minLength: 0)
            ReviewSendButton(viewModel: viewModel, onSend: onSend)
        }
        .padding(.horizontal, FlotillaSpacing.medium)
        .padding(.vertical, FlotillaSpacing.small)
        .background(FlotillaColors.sidebar)
    }

    private var pendingSummary: String {
        let unsent = viewModel.unsentComments.count
        let comments = unsent == 0 ? "no unsent comments" : "\(unsent) unsent comment\(unsent == 1 ? "" : "s")"
        return "\(comments)  ·  \(viewModel.viewedCount)/\(viewModel.files.count) viewed"
    }
}

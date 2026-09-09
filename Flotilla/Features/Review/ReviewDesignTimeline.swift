import SwiftUI
import GitKit
import DesignSystem

/// Design 3 — Timeline.
///
/// A guided walkthrough: a numbered step rail on the left tracks progress
/// through the files, the header states how far along the review is, and the
/// diff is a stack of floating hunk cards on a recessed canvas.
struct ReviewTimelineLayout: View {
    @Bindable var viewModel: SessionReviewViewModel
    let branch: String?
    @Binding var design: ReviewDesign
    @Binding var draft: ReviewCommentDraft?
    @Binding var draftText: String
    let onRefresh: () -> Void
    let onSend: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            HStack(spacing: 0) {
                stepRail
                Divider()
                ReviewDiffPane(viewModel: viewModel, draft: $draft, draftText: $draftText, style: .timeline)
            }
        }
        .onAppear { viewModel.fileDisplay = .allFiles }
    }

    // MARK: - Header

    private var header: some View {
        HStack(alignment: .center, spacing: FlotillaSpacing.large) {
            VStack(alignment: .leading, spacing: 3) {
                Text(headline)
                    .font(FlotillaTypography.headline)
                    .foregroundStyle(FlotillaColors.textPrimary)
                HStack(spacing: FlotillaSpacing.small) {
                    Text(viewModel.session.title)
                        .font(FlotillaTypography.caption2)
                        .foregroundStyle(FlotillaColors.textSecondary)
                        .lineLimit(1)
                    if let branch {
                        Text(branch)
                            .font(FlotillaTypography.caption2.monospaced())
                            .foregroundStyle(FlotillaColors.textTertiary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }
                ReviewProgressBar(viewed: viewModel.viewedCount, total: viewModel.files.count, height: 4)
                    .frame(width: 260)
                    .padding(.top, 2)
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

            ReviewSendButton(viewModel: viewModel, onSend: onSend)
            ReviewDesignMenu(design: $design)
        }
        .padding(.horizontal, FlotillaSpacing.large)
        .padding(.vertical, FlotillaSpacing.medium)
        .background(FlotillaColors.sidebar)
    }

    private var headline: String {
        let total = viewModel.files.count
        guard total > 0 else { return "Nothing to review" }
        return "Reviewing \(viewModel.viewedCount) of \(total) file\(total == 1 ? "" : "s")"
    }

    // MARK: - Step rail

    private var stepRail: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(viewModel.files.enumerated()), id: \.element.id) { index, file in
                    stepRow(index: index, file: file, isLast: index == viewModel.files.count - 1)
                }
            }
            .padding(.vertical, FlotillaSpacing.medium)
            .padding(.horizontal, FlotillaSpacing.small)
        }
        .frame(width: 264)
        .background(FlotillaColors.sidebar)
        .accessibilityIdentifier(AXID.reviewFileList.rawValue)
    }

    private func stepRow(index: Int, file: ReviewFile, isLast: Bool) -> some View {
        let isSelected = viewModel.selectedFile?.path == file.path
        return Button {
            viewModel.selectedPath = file.path
        } label: {
            HStack(alignment: .top, spacing: FlotillaSpacing.small) {
                VStack(spacing: 0) {
                    ZStack {
                        Circle()
                            .fill(file.isViewed ? FlotillaColors.statusReady : FlotillaColors.surface)
                            .frame(width: 22, height: 22)
                        Circle()
                            .strokeBorder(
                                isSelected ? FlotillaColors.accent : FlotillaColors.separator,
                                lineWidth: isSelected ? 2 : 1
                            )
                            .frame(width: 22, height: 22)
                        if file.isViewed {
                            Image(systemName: "checkmark").font(.system(size: 9, weight: .bold))
                                .foregroundStyle(FlotillaColors.accentContent)
                        } else {
                            Text("\(index + 1)").font(FlotillaTypography.caption3.weight(.semibold))
                                .foregroundStyle(FlotillaColors.textSecondary)
                        }
                    }
                    if !isLast {
                        Rectangle()
                            .fill(FlotillaColors.separator)
                            .frame(width: 1)
                            .frame(minHeight: 24)
                    }
                }

                VStack(alignment: .leading, spacing: 2) {
                    Text(file.filename)
                        .font(FlotillaTypography.caption.weight(.medium))
                        .foregroundStyle(isSelected ? FlotillaColors.textPrimary : FlotillaColors.textSecondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    HStack(spacing: FlotillaSpacing.xSmall) {
                        Text(file.change.kind.label)
                            .font(FlotillaTypography.caption3)
                            .foregroundStyle(file.change.kind.color)
                        DiffStatBadge(stat: file.change.stat)
                        if file.commentCount > 0 {
                            HStack(spacing: 1) {
                                Image(systemName: "bubble.left.fill").font(.system(size: 7))
                                Text("\(file.commentCount)").font(FlotillaTypography.caption3.weight(.semibold))
                            }
                            .foregroundStyle(FlotillaColors.accent)
                        }
                    }
                }
                .padding(.bottom, isLast ? 0 : FlotillaSpacing.medium)

                Spacer(minLength: 0)
            }
            .padding(.vertical, 4)
            .padding(.horizontal, FlotillaSpacing.xSmall)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                isSelected ? FlotillaColors.accent.opacity(FlotillaStateOpacity.selected) : .clear,
                in: RoundedRectangle(cornerRadius: FlotillaRadius.control, style: .continuous)
            )
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier(AXID.reviewFileRow(file.path))
    }
}

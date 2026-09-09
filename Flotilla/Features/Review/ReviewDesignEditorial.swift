import SwiftUI
import GitKit
import DesignSystem

/// Design 1 — Editorial.
///
/// The calm, familiar option: the full control strip on top, a thin viewed
/// progress bar under it, a flat alphabetical file list on the left, and the
/// diff as bordered cards.
struct ReviewEditorialLayout: View {
    @Bindable var viewModel: SessionReviewViewModel
    let branch: String?
    @Binding var design: ReviewDesign
    @Binding var draft: ReviewCommentDraft?
    @Binding var draftText: String
    let onRefresh: () -> Void
    let onSend: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            ReviewHeaderBar(
                viewModel: viewModel,
                branch: branch,
                onRefresh: onRefresh,
                onSend: onSend,
                trailing: { ReviewDesignMenu(design: $design) }
            )
            ReviewProgressBar(viewed: viewModel.viewedCount, total: viewModel.files.count, height: 3)
            Divider()

            HStack(spacing: 0) {
                ReviewFileStrip(viewModel: viewModel)
                Divider()
                ReviewDiffPane(viewModel: viewModel, draft: $draft, draftText: $draftText, style: .editorial)
            }
        }
        .onAppear { viewModel.fileDisplay = .allFiles }
    }
}

/// A flat, alphabetical file list — one row per changed file, no directory
/// tree. The row leads with the change-kind square and shows the filename
/// over its directory.
struct ReviewFileStrip: View {
    @Bindable var viewModel: SessionReviewViewModel
    @State private var query = ""

    private var files: [ReviewFile] {
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return viewModel.files }
        return viewModel.files.filter { $0.path.localizedCaseInsensitiveContains(trimmed) }
    }

    var body: some View {
        VStack(spacing: 0) {
            searchField
            Divider()

            if files.isEmpty {
                emptyState
            } else {
                ScrollView {
                    LazyVStack(spacing: 2) {
                        ForEach(files) { file in
                            row(file)
                        }
                    }
                    .padding(FlotillaSpacing.xSmall)
                }
            }

            Divider()
            footer
        }
        .frame(width: 288)
        .background(FlotillaColors.sidebar)
        .accessibilityIdentifier(AXID.reviewFileList.rawValue)
    }

    private func row(_ file: ReviewFile) -> some View {
        let isSelected = viewModel.selectedPath == file.path
        return Button {
            viewModel.selectedPath = file.path
        } label: {
            HStack(spacing: FlotillaSpacing.small) {
                FileChangeKindBadge(kind: file.change.kind, size: 18)

                VStack(alignment: .leading, spacing: 1) {
                    Text(file.filename)
                        .font(FlotillaTypography.caption.weight(.medium))
                        .foregroundStyle(file.isViewed && !isSelected ? FlotillaColors.textTertiary : FlotillaColors.textPrimary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    if let directory = file.directory {
                        Text(directory)
                            .font(FlotillaTypography.caption3)
                            .foregroundStyle(FlotillaColors.textTertiary)
                            .lineLimit(1)
                            .truncationMode(.head)
                    }
                }

                Spacer(minLength: FlotillaSpacing.xSmall)

                if file.commentCount > 0 {
                    HStack(spacing: 1) {
                        Image(systemName: "bubble.left.fill").font(.system(size: 7))
                        Text("\(file.commentCount)").font(FlotillaTypography.caption3.weight(.semibold))
                    }
                    .foregroundStyle(FlotillaColors.accent)
                }

                Button {
                    viewModel.toggleViewed(file)
                } label: {
                    Image(systemName: file.isViewed ? "checkmark.circle.fill" : "circle")
                        .font(.system(size: 12))
                        .foregroundStyle(file.isViewed ? FlotillaColors.statusReady : FlotillaColors.textTertiary)
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier(AXID.reviewFileViewed(file.path))
            }
            .padding(.horizontal, FlotillaSpacing.small)
            .padding(.vertical, 5)
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

    private var searchField: some View {
        HStack(spacing: FlotillaSpacing.small) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: FlotillaIconSize.xSmall))
                .foregroundStyle(FlotillaColors.textTertiary)
            TextField("Filter files…", text: $query)
                .textFieldStyle(.plain)
                .font(FlotillaTypography.caption)
        }
        .padding(.horizontal, FlotillaSpacing.small)
        .padding(.vertical, 6)
        .background(FlotillaColors.surface, in: RoundedRectangle(cornerRadius: FlotillaRadius.control, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: FlotillaRadius.control, style: .continuous)
                .strokeBorder(FlotillaColors.separator, lineWidth: FlotillaBorderWidth.hairline)
        }
        .padding(FlotillaSpacing.small)
    }

    private var footer: some View {
        HStack(spacing: FlotillaSpacing.small) {
            Text(files.count == 1 ? "1 file" : "\(files.count) files")
                .font(FlotillaTypography.caption2)
                .foregroundStyle(FlotillaColors.textSecondary)
            DiffStatBadge(stat: viewModel.totalStat)
            Spacer(minLength: 0)
            Text("\(viewModel.viewedCount)/\(viewModel.files.count) viewed")
                .font(FlotillaTypography.caption2)
                .foregroundStyle(FlotillaColors.textTertiary)
        }
        .padding(.horizontal, FlotillaSpacing.medium)
        .padding(.vertical, FlotillaSpacing.small)
    }

    private var emptyState: some View {
        VStack(spacing: FlotillaSpacing.small) {
            Spacer()
            Image(systemName: query.isEmpty ? "tray" : "magnifyingglass")
                .font(.system(size: FlotillaIconSize.large))
                .foregroundStyle(FlotillaColors.textTertiary)
            Text(query.isEmpty ? "No changes in this scope" : "No files match “\(query)”")
                .font(FlotillaTypography.caption)
                .foregroundStyle(FlotillaColors.textTertiary)
                .multilineTextAlignment(.center)
            Spacer()
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, FlotillaSpacing.medium)
    }
}

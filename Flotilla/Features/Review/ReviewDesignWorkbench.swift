import SwiftUI
import GitKit
import DesignSystem

/// Design 2 — Workbench.
///
/// A code-editor take: one file at a time, a narrow file switcher on the
/// left, a breadcrumb + prev/next strip on top, and a full-bleed diff that
/// meets the pane edges.
struct ReviewWorkbenchLayout: View {
    @Bindable var viewModel: SessionReviewViewModel
    let branch: String?
    @Binding var design: ReviewDesign
    @Binding var draft: ReviewCommentDraft?
    @Binding var draftText: String
    let onRefresh: () -> Void
    let onSend: () -> Void

    private var currentIndex: Int? {
        guard let path = viewModel.selectedFile?.path else { return nil }
        return viewModel.files.firstIndex { $0.path == path }
    }

    var body: some View {
        VStack(spacing: 0) {
            topBar
            Divider()
            HStack(spacing: 0) {
                rail
                Divider()
                ReviewDiffPane(viewModel: viewModel, draft: $draft, draftText: $draftText, style: .workbench)
            }
        }
        .onAppear { viewModel.fileDisplay = .singleFile }
    }

    // MARK: - Top bar

    private var topBar: some View {
        HStack(spacing: FlotillaSpacing.small) {
            stepper

            if let file = viewModel.selectedFile {
                FileChangeKindBadge(kind: file.change.kind, size: 16)
                Text(file.path)
                    .font(FlotillaTypography.caption.monospaced())
                    .foregroundStyle(FlotillaColors.textPrimary)
                    .lineLimit(1)
                    .truncationMode(.head)
                DiffStatBadge(stat: file.change.stat)

                Button {
                    viewModel.toggleViewed(file)
                } label: {
                    Label(file.isViewed ? "Viewed" : "Mark viewed",
                          systemImage: file.isViewed ? "checkmark.square.fill" : "square")
                        .font(FlotillaTypography.caption2)
                }
                .buttonStyle(.plain)
                .foregroundStyle(file.isViewed ? FlotillaColors.statusReady : FlotillaColors.textSecondary)
                .accessibilityIdentifier(AXID.reviewFileViewed(file.path))
            }

            Spacer(minLength: FlotillaSpacing.small)

            ReviewMiniControls(viewModel: viewModel, includeDisplay: false)
            refreshButton
            ReviewSendButton(viewModel: viewModel, onSend: onSend)
            ReviewDesignMenu(design: $design)
        }
        .padding(.horizontal, FlotillaSpacing.medium)
        .padding(.vertical, FlotillaSpacing.small)
        .background(FlotillaColors.sidebar)
    }

    private var stepper: some View {
        HStack(spacing: 2) {
            Button { step(-1) } label: {
                Image(systemName: "chevron.left").font(.system(size: FlotillaIconSize.xSmall, weight: .semibold))
            }
            .disabled((currentIndex ?? 0) <= 0)

            Text("\((currentIndex ?? 0) + 1) / \(max(viewModel.files.count, 1))")
                .font(FlotillaTypography.caption2.monospaced())
                .foregroundStyle(FlotillaColors.textSecondary)
                .frame(minWidth: 44)

            Button { step(1) } label: {
                Image(systemName: "chevron.right").font(.system(size: FlotillaIconSize.xSmall, weight: .semibold))
            }
            .disabled((currentIndex ?? 0) >= viewModel.files.count - 1)
        }
        .buttonStyle(.plain)
        .foregroundStyle(FlotillaColors.textSecondary)
    }

    private var refreshButton: some View {
        Button(action: onRefresh) {
            Image(systemName: "arrow.clockwise").font(.system(size: FlotillaIconSize.xSmall, weight: .semibold))
        }
        .buttonStyle(.plain)
        .foregroundStyle(FlotillaColors.textSecondary)
        .disabled(viewModel.isLoading)
        .accessibilityIdentifier(AXID.reviewRefresh.rawValue)
    }

    private func step(_ delta: Int) {
        guard let index = currentIndex else {
            viewModel.selectedPath = viewModel.files.first?.path
            return
        }
        let next = index + delta
        guard viewModel.files.indices.contains(next) else { return }
        viewModel.selectedPath = viewModel.files[next].path
    }

    // MARK: - Rail

    private var rail: some View {
        VStack(spacing: 0) {
            ScrollView {
                LazyVStack(spacing: 1) {
                    ForEach(viewModel.files) { file in
                        railRow(file)
                    }
                }
                .padding(.vertical, FlotillaSpacing.xSmall)
            }
            Divider()
            HStack {
                Text("\(viewModel.viewedCount)/\(viewModel.files.count) viewed")
                    .font(FlotillaTypography.caption3)
                    .foregroundStyle(FlotillaColors.textTertiary)
                Spacer()
            }
            .padding(.horizontal, FlotillaSpacing.small)
            .padding(.vertical, 6)
        }
        .frame(width: 204)
        .background(FlotillaColors.sidebar)
        .accessibilityIdentifier(AXID.reviewFileList.rawValue)
    }

    private func railRow(_ file: ReviewFile) -> some View {
        let isSelected = viewModel.selectedFile?.path == file.path
        return Button {
            viewModel.selectedPath = file.path
        } label: {
            HStack(spacing: FlotillaSpacing.xSmall) {
                Circle()
                    .fill(file.change.kind.color)
                    .frame(width: 6, height: 6)
                Text(file.filename)
                    .font(FlotillaTypography.caption2)
                    .foregroundStyle(file.isViewed && !isSelected ? FlotillaColors.textTertiary : FlotillaColors.textPrimary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 0)
                if file.commentCount > 0 {
                    Text("\(file.commentCount)")
                        .font(FlotillaTypography.caption3.weight(.semibold))
                        .foregroundStyle(FlotillaColors.accent)
                }
                if file.isViewed {
                    Image(systemName: "checkmark").font(.system(size: 8, weight: .bold))
                        .foregroundStyle(FlotillaColors.statusReady)
                }
            }
            .padding(.horizontal, FlotillaSpacing.small)
            .padding(.vertical, 4)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(isSelected ? FlotillaColors.accent.opacity(FlotillaStateOpacity.selected) : .clear)
            .overlay(alignment: .leading) {
                if isSelected {
                    Rectangle().fill(FlotillaColors.accent).frame(width: FlotillaBorderWidth.thick)
                }
            }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier(AXID.reviewFileRow(file.path))
    }
}

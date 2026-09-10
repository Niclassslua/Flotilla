import SwiftUI
import GitKit
import DesignSystem

/// The review's left rail: the changed files as one flat, alphabetical list
/// with a filter above and a viewed-progress footer below.
///
/// Flat rather than a directory tree: a review is a finite, already-scoped
/// set of files you work through top to bottom, and a tree spends a column of
/// indent and a row per folder to arrange a list you mostly read in order.
struct ReviewFileList: View {
    @Bindable var viewModel: SessionReviewViewModel

    @State private var query = ""

    var body: some View {
        VStack(spacing: 0) {
            searchField
            Divider()

            if matchingFiles.isEmpty {
                emptyState
            } else {
                list
            }

            Divider()
            footer
        }
        .frame(width: 300)
        .background(FlotillaColors.sidebar)
        .accessibilityIdentifier(AXID.reviewFileList.rawValue)
    }

    // MARK: - Chrome

    private var searchField: some View {
        HStack(spacing: FlotillaSpacing.small) {
            Image(systemName: "line.3.horizontal.decrease")
                .font(.system(size: FlotillaIconSize.xSmall, weight: .semibold))
                .foregroundStyle(FlotillaColors.textTertiary)
            TextField("Filter files", text: $query)
                .textFieldStyle(.plain)
                .font(FlotillaTypography.caption)
                .foregroundStyle(FlotillaColors.textPrimary)
            if !query.isEmpty {
                Button {
                    query = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: FlotillaIconSize.xSmall))
                        .foregroundStyle(FlotillaColors.textTertiary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Clear filter")
            }
        }
        .padding(.horizontal, FlotillaSpacing.small)
        .padding(.vertical, 6)
        .background(
            FlotillaColors.surface,
            in: RoundedRectangle(cornerRadius: FlotillaRadius.control, style: .continuous)
        )
        .overlay {
            RoundedRectangle(cornerRadius: FlotillaRadius.control, style: .continuous)
                .strokeBorder(FlotillaColors.separator, lineWidth: FlotillaBorderWidth.hairline)
        }
        .padding(FlotillaSpacing.small)
    }

    private var list: some View {
        ScrollView {
            LazyVStack(spacing: 1) {
                ForEach(matchingFiles) { file in
                    ReviewFileRow(
                        file: file,
                        isSelected: viewModel.selectedPath == file.path,
                        onSelect: { viewModel.selectedPath = file.path },
                        onToggleViewed: { viewModel.toggleViewed(file) }
                    )
                }
            }
            .padding(.horizontal, FlotillaSpacing.xSmall)
            .padding(.vertical, FlotillaSpacing.xSmall)
        }
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
        .accessibilityIdentifier(AXID.reviewEmpty.rawValue)
    }

    /// How much is in front of you, how much of it you have read, and — as a
    /// thin fill along the top edge — the same figure at a glance.
    private var footer: some View {
        VStack(spacing: 0) {
            ReviewViewedProgressBar(viewed: viewModel.viewedCount, total: viewModel.files.count)
                .frame(height: 2)

            HStack(spacing: FlotillaSpacing.small) {
                Text(matchingFiles.count == 1 ? "1 file" : "\(matchingFiles.count) files")
                    .font(FlotillaTypography.caption2)
                    .foregroundStyle(FlotillaColors.textSecondary)

                DiffStatBadge(stat: totalStat)

                Spacer(minLength: 0)

                Text("\(viewModel.viewedCount)/\(viewModel.files.count) viewed")
                    .font(FlotillaTypography.caption2)
                    .foregroundStyle(FlotillaColors.textTertiary)
                    .accessibilityIdentifier(AXID.reviewProgress.rawValue)
            }
            .padding(.horizontal, FlotillaSpacing.medium)
            .padding(.vertical, FlotillaSpacing.small)
        }
    }

    // MARK: - Derived

    private var matchingFiles: [ReviewFile] {
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return viewModel.files }
        return viewModel.files.filter { $0.path.localizedCaseInsensitiveContains(trimmed) }
    }

    private var totalStat: GitDiffStat {
        matchingFiles.reduce(GitDiffStat(additions: 0, deletions: 0)) { $0 + $1.change.stat }
    }
}

/// One file in the flat list: change-kind square, filename over its folder,
/// then per-file signal — line counts, comments, and a viewed tick.
struct ReviewFileRow: View {
    let file: ReviewFile
    let isSelected: Bool
    let onSelect: () -> Void
    let onToggleViewed: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: onSelect) {
            HStack(spacing: FlotillaSpacing.small) {
                FileChangeKindBadge(kind: file.change.kind, size: 16)
                    .opacity(dimmed ? 0.55 : 1)

                VStack(alignment: .leading, spacing: 1) {
                    Text(file.filename)
                        .font(FlotillaTypography.caption.weight(.medium))
                        .foregroundStyle(nameColor)
                        .strikethrough(file.change.kind == .deleted, color: nameColor.opacity(0.6))
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

                trailingSignal
            }
            .padding(.horizontal, FlotillaSpacing.small)
            .padding(.vertical, 5)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                rowBackground,
                in: RoundedRectangle(cornerRadius: FlotillaRadius.control, style: .continuous)
            )
            .overlay(alignment: .leading) {
                if isSelected {
                    Capsule()
                        .fill(FlotillaColors.accent)
                        .frame(width: FlotillaBorderWidth.thick)
                        .padding(.vertical, 4)
                }
            }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .accessibilityIdentifier(AXID.reviewFileRow(file.path))
    }

    // MARK: - Trailing

    private var trailingSignal: some View {
        HStack(spacing: FlotillaSpacing.xSmall) {
            if file.commentCount > 0 {
                HStack(spacing: 1) {
                    Image(systemName: "bubble.left.fill").font(.system(size: 7))
                    Text("\(file.commentCount)").font(FlotillaTypography.caption3.weight(.semibold))
                }
                .foregroundStyle(FlotillaColors.accent)
                .accessibilityLabel("\(file.commentCount) comment\(file.commentCount == 1 ? "" : "s")")
            }

            if !isHovering && !isSelected {
                ReviewMiniStat(stat: file.change.stat)
            }

            Button(action: onToggleViewed) {
                Image(systemName: file.isViewed ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 12))
                    .foregroundStyle(file.isViewed ? FlotillaColors.statusReady : FlotillaColors.textTertiary)
            }
            .buttonStyle(.plain)
            .opacity(file.isViewed || isHovering || isSelected ? 1 : 0)
            .help(file.isViewed ? "Mark as not viewed" : "Mark as viewed")
            .accessibilityLabel(file.isViewed ? "Viewed" : "Not viewed")
            .accessibilityIdentifier(AXID.reviewFileViewed(file.path))
        }
    }

    // MARK: - Derived

    private var dimmed: Bool { file.isViewed && !isSelected }

    private var nameColor: Color {
        dimmed ? FlotillaColors.textTertiary : FlotillaColors.textPrimary
    }

    private var rowBackground: Color {
        if isSelected { return FlotillaColors.accent.opacity(FlotillaStateOpacity.selected) }
        if isHovering { return FlotillaColors.textPrimary.opacity(FlotillaStateOpacity.hover) }
        return .clear
    }
}

/// A very compact two-number line-count readout: `+12 −4` in the diff
/// colours, no chips — quieter than ``DiffStatBadge`` for a dense list row.
struct ReviewMiniStat: View {
    let stat: GitDiffStat

    var body: some View {
        HStack(spacing: 3) {
            if stat.additions > 0 {
                Text("+\(stat.additions)")
                    .foregroundStyle(FlotillaColors.diffAdded)
            }
            if stat.deletions > 0 {
                Text("−\(stat.deletions)")
                    .foregroundStyle(FlotillaColors.diffRemoved)
            }
        }
        .font(.system(size: 10, weight: .medium, design: .monospaced))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(stat.additions) added, \(stat.deletions) removed")
    }
}

/// The thin viewed-progress fill shared by the file-list footer and the
/// header bar's bottom edge.
struct ReviewViewedProgressBar: View {
    let viewed: Int
    let total: Int

    private var fraction: Double {
        guard total > 0 else { return 0 }
        return min(1, Double(viewed) / Double(total))
    }

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Rectangle().fill(FlotillaColors.separator.opacity(0.5))
                Rectangle()
                    .fill(FlotillaColors.statusReady)
                    .frame(width: geo.size.width * fraction)
            }
        }
        .animation(FlotillaMotion.normal.curve, value: fraction)
        .accessibilityHidden(true)
    }
}

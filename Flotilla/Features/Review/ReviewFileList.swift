import SwiftUI
import GitKit
import DesignSystem

/// The review's left rail: the changed files as a directory tree, with a
/// search field above and a running total below.
struct ReviewFileList: View {
    @Bindable var viewModel: SessionReviewViewModel

    @State private var query = ""
    /// Directories the reviewer has folded away. Absent means expanded, so a
    /// newly appearing directory is open rather than hidden.
    @State private var collapsed: Set<String> = []

    var body: some View {
        VStack(spacing: 0) {
            searchField
            Divider()

            if matchingFiles.isEmpty {
                emptyState
            } else {
                tree
            }

            Divider()
            footer
        }
        .frame(width: 360)
        .background(FlotillaColors.sidebar)
        .accessibilityIdentifier(AXID.reviewFileList.rawValue)
    }

    // MARK: - Chrome

    private var searchField: some View {
        HStack(spacing: FlotillaSpacing.small) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: FlotillaIconSize.small))
                .foregroundStyle(FlotillaColors.textTertiary)
            TextField("Search…", text: $query)
                .textFieldStyle(.plain)
                .font(FlotillaTypography.callout)
                .autocorrectionDisabled()
                .textContentType(nil)
                .foregroundStyle(FlotillaColors.textPrimary)
            if !query.isEmpty {
                Button {
                    query = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: FlotillaIconSize.small))
                        .foregroundStyle(FlotillaColors.textTertiary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Clear search")
            }
        }
        .padding(.horizontal, FlotillaSpacing.small)
        .padding(.vertical, 8)
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

    private var tree: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(nodes) { node in
                    ReviewTreeRowGroup(
                        node: node,
                        depth: 0,
                        viewModel: viewModel,
                        collapsed: $collapsed
                    )
                }
            }
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
                .font(FlotillaTypography.callout)
                .foregroundStyle(FlotillaColors.textTertiary)
                .multilineTextAlignment(.center)
            Spacer()
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, FlotillaSpacing.medium)
        .accessibilityIdentifier(AXID.reviewEmpty.rawValue)
    }

    /// Mirrors the reference navigator's status line: how much is in front of
    /// you, and how much of it you have already read — as a count, and as the
    /// same thin fill that runs along the header's bottom edge.
    private var footer: some View {
        VStack(spacing: 0) {
            ReviewViewedProgressBar(viewed: viewModel.viewedCount, total: viewModel.files.count)
                .frame(height: 2)

            HStack(spacing: FlotillaSpacing.small) {
                Text(matchingFiles.count == 1 ? "1 file" : "\(matchingFiles.count) files")
                    .font(FlotillaTypography.caption)
                    .foregroundStyle(FlotillaColors.textSecondary)

                DiffStatBadge(stat: totalStat)

                Spacer(minLength: 0)

                Text("\(viewModel.viewedCount)/\(viewModel.files.count) viewed")
                    .font(FlotillaTypography.caption)
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

    private var nodes: [ReviewTreeNode] {
        ReviewFileTreeBuilder.build(from: matchingFiles)
    }

    private var totalStat: GitDiffStat {
        matchingFiles.reduce(GitDiffStat(additions: 0, deletions: 0)) { $0 + $1.change.stat }
    }
}

/// One node and, when it is an expanded directory, everything under it.
private struct ReviewTreeRowGroup: View {
    let node: ReviewTreeNode
    let depth: Int
    @Bindable var viewModel: SessionReviewViewModel
    @Binding var collapsed: Set<String>

    var body: some View {
        if let file = node.file {
            ReviewFileRow(
                file: file,
                name: node.name,
                depth: depth,
                isSelected: viewModel.selectedPath == file.path,
                onSelect: { viewModel.selectedPath = file.path },
                onToggleViewed: { viewModel.toggleViewed(file) }
            )
        } else {
            ReviewDirectoryRow(
                node: node,
                depth: depth,
                isExpanded: !collapsed.contains(node.path),
                onToggle: {
                    if collapsed.contains(node.path) {
                        collapsed.remove(node.path)
                    } else {
                        collapsed.insert(node.path)
                    }
                }
            )

            if !collapsed.contains(node.path) {
                ForEach(node.children) { child in
                    ReviewTreeRowGroup(
                        node: child,
                        depth: depth + 1,
                        viewModel: viewModel,
                        collapsed: $collapsed
                    )
                }
            }
        }
    }
}

private struct ReviewDirectoryRow: View {
    let node: ReviewTreeNode
    let depth: Int
    let isExpanded: Bool
    let onToggle: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: onToggle) {
            HStack(spacing: FlotillaSpacing.xSmall) {
                Image(systemName: "chevron.right")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(FlotillaColors.textTertiary)
                    .rotationEffect(.degrees(isExpanded ? 90 : 0))
                    .frame(width: 12)

                Text(node.name)
                    .font(FlotillaTypography.callout)
                    .foregroundStyle(FlotillaColors.textSecondary)
                    .lineLimit(1)
                    .truncationMode(.middle)

                Spacer(minLength: FlotillaSpacing.xSmall)

                // A dot rather than a count: the folder's own status is not a
                // thing you act on, and a number here competes with the file
                // rows' change markers.
                Circle()
                    .fill(FlotillaColors.textTertiary.opacity(0.55))
                    .frame(width: 5, height: 5)
            }
            .padding(.leading, ReviewTreeMetrics.indent(depth))
            .padding(.trailing, FlotillaSpacing.medium)
            .padding(.vertical, 4)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(isHovering ? Color.white.opacity(FlotillaStateOpacity.hover) : .clear)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .accessibilityLabel("\(node.name) folder")
        .accessibilityValue(isExpanded ? "Expanded" : "Collapsed")
    }
}

struct ReviewFileRow: View {
    let file: ReviewFile
    let name: String
    let depth: Int
    let isSelected: Bool
    let onSelect: () -> Void
    let onToggleViewed: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: onSelect) {
            HStack(spacing: FlotillaSpacing.small) {
                MaterialFileIcon(url: URL(fileURLWithPath: file.path), size: 16)
                    .accessibilityHidden(true)

                Text(name)
                    .font(FlotillaTypography.callout)
                    .foregroundStyle(nameColor)
                    .strikethrough(file.change.kind == .deleted, color: nameColor.opacity(0.7))
                    .lineLimit(1)
                    .truncationMode(.middle)

                Spacer(minLength: FlotillaSpacing.xSmall)

                if file.commentCount > 0 {
                    commentBadge
                }

                viewedTick

                Text(file.change.kind.marker)
                    .font(FlotillaTypography.caption.weight(.bold).monospaced())
                    .foregroundStyle(file.change.kind.color)
                    .frame(width: 12, alignment: .trailing)
                    .accessibilityLabel(file.change.kind.label)
            }
            .padding(.leading, ReviewTreeMetrics.indent(depth))
            .padding(.trailing, FlotillaSpacing.medium)
            .padding(.vertical, 4)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(rowBackground)
            .overlay(alignment: .leading) {
                if isSelected {
                    Rectangle()
                        .fill(FlotillaColors.accent)
                        .frame(width: FlotillaBorderWidth.thick)
                }
            }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .accessibilityIdentifier(AXID.reviewFileRow(file.path))
    }

    /// Shown once ticked, and on hover so an unticked file advertises that it
    /// can be ticked. Otherwise the rail stays as quiet as the reference.
    @ViewBuilder
    private var viewedTick: some View {
        if file.isViewed || isHovering {
            Button(action: onToggleViewed) {
                Image(systemName: file.isViewed ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 13))
                    .foregroundStyle(file.isViewed ? FlotillaColors.statusReady : FlotillaColors.textTertiary)
            }
            .buttonStyle(.plain)
            .help(file.isViewed ? "Mark as not viewed" : "Mark as viewed")
            .accessibilityLabel(file.isViewed ? "Viewed" : "Not viewed")
            .accessibilityIdentifier(AXID.reviewFileViewed(file.path))
        }
    }

    private var commentBadge: some View {
        HStack(spacing: 2) {
            Image(systemName: "bubble.left.fill")
                .font(.system(size: 9))
            Text("\(file.commentCount)")
                .font(FlotillaTypography.caption2.weight(.semibold))
        }
        .foregroundStyle(FlotillaColors.accent)
        .accessibilityLabel("\(file.commentCount) comment\(file.commentCount == 1 ? "" : "s")")
    }

    /// Colour carries the change kind, matching the marker on the right, and
    /// a read file recedes.
    private var nameColor: Color {
        if file.isViewed && !isSelected { return FlotillaColors.textTertiary }
        return file.change.kind.color
    }

    private var rowBackground: Color {
        if isSelected { return FlotillaColors.accent.opacity(FlotillaStateOpacity.selected) }
        if isHovering { return Color.white.opacity(FlotillaStateOpacity.hover) }
        return .clear
    }
}

enum ReviewTreeMetrics {
    /// Indent per level, plus the room the root rows need so their icons line
    /// up under a directory chevron.
    static func indent(_ depth: Int) -> CGFloat {
        FlotillaSpacing.small + CGFloat(depth) * 12
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

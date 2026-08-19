import SwiftUI
import AppKit
import GitKit
import DesignSystem

/// The right-hand pane of the history view: everything about one commit —
/// identity, decoration, what it touched, and the patch itself.
struct CommitDetailView: View {
    @Bindable var viewModel: ProjectHistoryViewModel

    private var commit: GitCommit? {
        viewModel.commits.first { $0.sha == viewModel.selectedSHA }
    }

    var body: some View {
        Group {
            if let commit {
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        header(commit)
                        Divider()
                        identity(commit)
                        Divider()
                        statSummary(commit)
                        Divider()
                        fileSection(commit)
                    }
                }
                .scrollContentBackground(.hidden)
            } else {
                ContentUnavailableView(
                    "No Commit Selected",
                    systemImage: "circle.dashed",
                    description: Text("Pick a commit from the timeline to inspect it.")
                )
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(FlotillaColors.canvas)
        .accessibilityIdentifier("ProjectHistory.Detail")
    }

    // MARK: - Header

    private func header(_ commit: GitCommit) -> some View {
        VStack(alignment: .leading, spacing: FlotillaSpacing.small) {
            Text(commit.subject)
                .font(FlotillaTypography.headline)
                .foregroundStyle(FlotillaColors.textPrimary)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)

            if !commit.body.isEmpty {
                Text(commit.body)
                    .font(FlotillaTypography.callout)
                    .foregroundStyle(FlotillaColors.textSecondary)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack(spacing: FlotillaSpacing.small) {
                Text(commit.shortSHA)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(FlotillaColors.textSecondary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(FlotillaColors.surfaceElevated, in: RoundedRectangle(cornerRadius: FlotillaRadius.control))
                    .textSelection(.enabled)

                Button {
                    copy(commit.sha)
                } label: {
                    Image(systemName: "doc.on.doc")
                        .font(.system(size: FlotillaIconSize.small))
                }
                .buttonStyle(.plain)
                .foregroundStyle(FlotillaColors.textTertiary)
                .help("Copy the full SHA")
                .accessibilityIdentifier("ProjectHistory.CopySHAButton")

                if let url = viewModel.webURL(for: commit) {
                    Link(destination: url) {
                        HStack(spacing: 3) {
                            Image(systemName: "arrow.up.right.square")
                                .font(.system(size: FlotillaIconSize.small))
                            Text("Open on the Web")
                                .font(FlotillaTypography.caption2)
                        }
                    }
                    .accessibilityIdentifier("ProjectHistory.WebLink")
                }

                Spacer()

                if viewModel.isUnpushed(commit) {
                    CommitRefChip(text: "not pushed", systemImage: "arrow.up.circle", tint: FlotillaColors.accent)
                }
            }
        }
        .padding(FlotillaSpacing.large)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Identity

    private func identity(_ commit: GitCommit) -> some View {
        VStack(alignment: .leading, spacing: FlotillaSpacing.small) {
            HStack(alignment: .top, spacing: FlotillaSpacing.small) {
                ProjectMark(
                    title: commit.authorName,
                    tint: ProjectMark.tint(forKey: commit.authorEmail),
                    size: 28
                )
                VStack(alignment: .leading, spacing: 1) {
                    Text(commit.authorName)
                        .font(FlotillaTypography.callout.weight(.medium))
                        .foregroundStyle(FlotillaColors.textPrimary)
                    Text(commit.authorEmail)
                        .font(FlotillaTypography.caption2)
                        .foregroundStyle(FlotillaColors.textTertiary)
                        .textSelection(.enabled)
                    Text("authored \(commit.authorDate.formatted(date: .abbreviated, time: .shortened))")
                        .font(FlotillaTypography.caption2)
                        .foregroundStyle(FlotillaColors.textSecondary)
                    if let attribution = viewModel.attribution(for: commit) {
                        HStack(spacing: 4) {
                            ProviderLogo(agent: attribution.agent)
                                .frame(width: 12, height: 12)
                            Text(attribution.sessionTitle.map { "\(attribution.agent.displayName) · \($0)" }
                                 ?? attribution.agent.displayName)
                                .font(FlotillaTypography.caption2)
                                .foregroundStyle(FlotillaColors.accent)
                                .lineLimit(1)
                            Text(attribution.source.explanation)
                                .font(FlotillaTypography.caption2)
                                .foregroundStyle(FlotillaColors.textTertiary)
                        }
                        .padding(.top, 1)
                        .accessibilityIdentifier("ProjectHistory.Attribution")
                    }
                    // Only shown when it differs — a rebase or an amend by
                    // someone else. Otherwise it's noise.
                    if commit.hasDistinctCommitter {
                        Text("committed by \(commit.committerName) · \(commit.committerDate.formatted(date: .abbreviated, time: .shortened))")
                            .font(FlotillaTypography.caption2)
                            .foregroundStyle(FlotillaColors.textTertiary)
                    }
                }
                Spacer()
            }

            if !commit.refs.isEmpty {
                HStack(spacing: FlotillaSpacing.xSmall) {
                    ForEach(Array(commit.refs.enumerated()), id: \.offset) { _, ref in
                        CommitRefChip(ref: ref)
                    }
                    Spacer(minLength: 0)
                }
            }

            if !commit.parents.isEmpty {
                HStack(spacing: FlotillaSpacing.xSmall) {
                    Text(commit.parents.count > 1 ? "parents" : "parent")
                        .font(FlotillaTypography.caption2)
                        .foregroundStyle(FlotillaColors.textTertiary)
                    ForEach(commit.parents, id: \.self) { parent in
                        parentButton(parent)
                    }
                    Spacer(minLength: 0)
                }
            }
        }
        .padding(.horizontal, FlotillaSpacing.large)
        .padding(.vertical, FlotillaSpacing.medium)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// Navigating to a parent keeps the pane useful for walking back through
    /// history. Only parents present in the loaded page are reachable.
    private func parentButton(_ parent: String) -> some View {
        let isLoaded = viewModel.commits.contains { $0.sha == parent }
        return Button {
            if isLoaded { viewModel.selectedSHA = parent }
        } label: {
            Text(String(parent.prefix(7)))
                .font(.system(size: 10, design: .monospaced))
                .padding(.horizontal, 5)
                .padding(.vertical, 1.5)
                .background(FlotillaColors.surfaceElevated, in: Capsule())
                .foregroundStyle(isLoaded ? FlotillaColors.textSecondary : FlotillaColors.textTertiary)
        }
        .buttonStyle(.plain)
        .disabled(!isLoaded)
        .help(isLoaded ? "Jump to this parent" : "This parent isn't in the loaded history yet")
    }

    // MARK: - Stat summary

    private func statSummary(_ commit: GitCommit) -> some View {
        let stat = viewModel.detail?.stat ?? commit.stat
        let fileCount = viewModel.detail?.files.count ?? commit.changedFileCount
        return VStack(alignment: .leading, spacing: FlotillaSpacing.small) {
            HStack(spacing: FlotillaSpacing.small) {
                Text("\(fileCount) file\(fileCount == 1 ? "" : "s") changed")
                    .font(FlotillaTypography.caption.weight(.medium))
                    .foregroundStyle(FlotillaColors.textSecondary)
                Spacer()
                if !stat.isEmpty {
                    DiffStatBadge(stat: stat)
                }
            }
            if !stat.isEmpty {
                proportionBar(stat)
            }
        }
        .padding(.horizontal, FlotillaSpacing.large)
        .padding(.vertical, FlotillaSpacing.medium)
    }

    /// Additions-to-deletions at a glance, in the manner of `HomeFleetBar`.
    private func proportionBar(_ stat: GitDiffStat) -> some View {
        GeometryReader { geometry in
            let total = max(1, stat.additions + stat.deletions)
            let addedWidth = geometry.size.width * CGFloat(stat.additions) / CGFloat(total)
            HStack(spacing: 1) {
                Capsule().fill(FlotillaColors.diffAdded).frame(width: max(0, addedWidth - 1))
                Capsule().fill(FlotillaColors.diffRemoved)
            }
        }
        .frame(height: 4)
        .accessibilityHidden(true)
    }

    // MARK: - Files

    @ViewBuilder
    private func fileSection(_ commit: GitCommit) -> some View {
        if viewModel.isLoadingDetail {
            HStack(spacing: FlotillaSpacing.small) {
                ProgressView().controlSize(.small)
                Text("Loading changes…")
                    .font(FlotillaTypography.caption)
                    .foregroundStyle(FlotillaColors.textTertiary)
            }
            .padding(FlotillaSpacing.large)
        } else if let detail = viewModel.detail, !detail.files.isEmpty {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(detail.files) { file in
                    CommitFileRow(file: file, repoPath: viewModel.repoPath)
                    Divider().opacity(0.5)
                }
            }
        } else if commit.isMerge {
            // Not an error: `git show` reports no changes for a merge unless
            // asked to diff against a specific parent.
            hint("This is a merge commit. Its changes belong to the commits it brings in.")
        } else {
            hint("This commit touched no files.")
        }
    }

    private func hint(_ text: String) -> some View {
        Text(text)
            .font(FlotillaTypography.callout)
            .foregroundStyle(FlotillaColors.textTertiary)
            .padding(FlotillaSpacing.large)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}

// MARK: - File row

/// One changed file, expanding to reveal its hunks. Collapsed by default so a
/// wide-reaching commit stays scannable.
struct CommitFileRow: View {
    let file: GitCommitFileChange
    let repoPath: URL

    @State private var isExpanded = false
    @State private var isHovering = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            if isExpanded {
                if file.hunks.isEmpty {
                    Text(emptyHunkExplanation)
                        .font(FlotillaTypography.caption2)
                        .foregroundStyle(FlotillaColors.textTertiary)
                        .padding(.horizontal, FlotillaSpacing.large)
                        .padding(.bottom, FlotillaSpacing.small)
                } else {
                    ForEach(Array(file.hunks.enumerated()), id: \.offset) { _, hunk in
                        CommitHunkView(hunk: hunk)
                    }
                }
            }
        }
        .background(isHovering && !isExpanded ? FlotillaColors.textPrimary.opacity(FlotillaStateOpacity.hover) : .clear)
        .accessibilityIdentifier("ProjectHistory.File-\(file.path)")
    }

    private var header: some View {
        HStack(spacing: FlotillaSpacing.small) {
            Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(FlotillaColors.textTertiary)
                .frame(width: 10)

            Text(kindMarker)
                .font(.system(size: 10, weight: .bold, design: .monospaced))
                .foregroundStyle(kindColor)
                .frame(width: 14)

            VStack(alignment: .leading, spacing: 1) {
                Text(file.path)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(FlotillaColors.textPrimary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                if let previousPath = file.previousPath {
                    Text("was \(previousPath)")
                        .font(.system(size: 9, design: .monospaced))
                        .foregroundStyle(FlotillaColors.textTertiary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }

            Spacer(minLength: FlotillaSpacing.small)

            if !file.stat.isEmpty {
                DiffStatBadge(stat: file.stat)
            }
        }
        .padding(.horizontal, FlotillaSpacing.large)
        .padding(.vertical, FlotillaSpacing.small)
        .contentShape(.rect)
        .onTapGesture { withAnimation(FlotillaMotion.fast.curve) { isExpanded.toggle() } }
        .onHover { isHovering = $0 }
        .contextMenu {
            Button("Copy Path") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(file.path, forType: .string)
            }
            Button("Reveal in Finder") {
                NSWorkspace.shared.activateFileViewerSelecting([repoPath.appendingPathComponent(file.path)])
            }
            .disabled(file.kind == .deleted)
        }
    }

    private var emptyHunkExplanation: String {
        switch file.kind {
        case .renamed, .copied: return "No content changes — the file only moved."
        default: return "No textual diff (this may be a binary file)."
        }
    }

    private var kindMarker: String {
        switch file.kind {
        case .added: return "A"
        case .modified: return "M"
        case .deleted: return "D"
        case .renamed: return "R"
        case .copied: return "C"
        case .typeChanged: return "T"
        case .unmerged: return "U"
        }
    }

    private var kindColor: Color {
        switch file.kind {
        case .added: return FlotillaColors.diffAdded
        case .deleted: return FlotillaColors.diffRemoved
        case .modified: return FlotillaColors.accent
        case .renamed, .copied: return FlotillaColors.textSecondary
        case .typeChanged, .unmerged: return FlotillaColors.warning
        }
    }
}

// MARK: - Hunk

/// A unified-diff hunk. Wide lines scroll horizontally within the hunk rather
/// than forcing the whole pane sideways.
struct CommitHunkView: View {
    let hunk: FileDiffHunk

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(hunk.header)
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(FlotillaColors.textTertiary)
                .padding(.horizontal, FlotillaSpacing.large)
                .padding(.vertical, 3)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(FlotillaColors.surfaceElevated)

            ScrollView(.horizontal, showsIndicators: false) {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(hunk.lines.enumerated()), id: \.offset) { _, line in
                        Text(line.isEmpty ? " " : line)
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(foreground(for: line))
                            .padding(.horizontal, FlotillaSpacing.large)
                            .padding(.vertical, 0.5)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(background(for: line))
                            .textSelection(.enabled)
                    }
                }
            }
        }
    }

    private func background(for line: String) -> Color {
        if line.hasPrefix("+") { return FlotillaColors.diffAddedSurface }
        if line.hasPrefix("-") { return FlotillaColors.diffRemovedSurface }
        return .clear
    }

    private func foreground(for line: String) -> Color {
        if line.hasPrefix("+") { return FlotillaColors.diffAdded }
        if line.hasPrefix("-") { return FlotillaColors.diffRemoved }
        return FlotillaColors.textSecondary
    }
}

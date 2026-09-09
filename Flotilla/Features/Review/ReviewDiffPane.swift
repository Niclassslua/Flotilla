import SwiftUI
import GitKit
import SessionKit
import DesignSystem

/// Where a comment is being composed. One at a time across the whole review:
/// two open editors would make it ambiguous which one ⌘↩ submits.
struct ReviewCommentDraft: Equatable, Identifiable {
    let path: String
    let anchor: ReviewCommentAnchor
    /// Set when editing an existing comment rather than writing a new one.
    var editing: UUID?

    var id: String {
        switch anchor {
        case .file: "\(path)#file"
        case let .line(side, number): "\(path)#\(side.rawValue):\(number)"
        }
    }
}

/// The diff half of the review window.
struct ReviewDiffPane: View {
    @Bindable var viewModel: SessionReviewViewModel
    @Binding var draft: ReviewCommentDraft?
    @Binding var draftText: String
    /// Container styling turned by the active ``ReviewDesign``. The diff
    /// rendering itself is unaffected — only the frame around it.
    var style: ReviewDiffStyle = .standard

    /// Measured, not guessed: the two side-by-side columns are each half of
    /// it, which is what makes the diff fill the window instead of sitting in
    /// a fixed-width strip with dead space beside it.
    @State private var paneWidth: CGFloat = 0

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(
                    alignment: .leading,
                    spacing: style.sectionSpacing,
                    pinnedViews: style.stickyHeaders ? [.sectionHeaders] : []
                ) {
                    ForEach(viewModel.visibleFiles) { file in
                        ReviewFileSection(
                            file: file,
                            viewModel: viewModel,
                            availableWidth: contentWidth,
                            style: style,
                            draft: $draft,
                            draftText: $draftText
                        )
                        .id(file.path)
                    }
                }
                .padding(style.outerPadding)
            }
            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { paneWidth = $0 }
            .background(style.canvas)
            // In All Files the file list scrolls this pane rather than
            // swapping its contents; in Single File the pane is already just
            // that file, so the scroll is a no-op and harmless.
            .onChange(of: viewModel.selectedPath) { _, newValue in
                guard let newValue else { return }
                withAnimation(FlotillaMotion.fast.curve) {
                    proxy.scrollTo(newValue, anchor: .top)
                }
            }
        }
        .accessibilityIdentifier(AXID.reviewDiffPane.rawValue)
    }

    /// The pane minus the padding and the file card's own border.
    private var contentWidth: CGFloat {
        max(0, paneWidth - style.outerPadding * 2)
    }
}

/// One file: a sticky header, then its hunks in whichever layout is selected.
struct ReviewFileSection: View {
    let file: ReviewFile
    @Bindable var viewModel: SessionReviewViewModel
    let availableWidth: CGFloat
    var style: ReviewDiffStyle = .standard
    @Binding var draft: ReviewCommentDraft?
    @Binding var draftText: String

    var body: some View {
        Section {
            body(for: styledContent)
        } header: {
            header
        }
        .accessibilityIdentifier(AXID.reviewFileSection(file.path))
    }

    private var styledContent: some View {
        VStack(alignment: .leading, spacing: 0) {
            fileComments

            if file.hasNoRenderableDiff {
                Text(file.emptyDiffExplanation)
                    .font(FlotillaTypography.caption)
                    .foregroundStyle(FlotillaColors.textTertiary)
                    .padding(FlotillaSpacing.medium)
            } else {
                ForEach(Array(file.hunks.enumerated()), id: \.offset) { _, hunk in
                    hunkView(hunk)
                }
            }
        }
    }

    /// The frame around a file's hunks, per the active design.
    @ViewBuilder
    private func body(for content: some View) -> some View {
        switch style.fileContainer {
        case .card:
            content
                .background(FlotillaColors.surface)
                .clipShape(RoundedRectangle(cornerRadius: FlotillaRadius.card, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: FlotillaRadius.card, style: .continuous)
                        .strokeBorder(FlotillaColors.separator, lineWidth: FlotillaBorderWidth.hairline)
                }
        case .floating:
            content
                .background(FlotillaColors.surface)
                .clipShape(RoundedRectangle(cornerRadius: FlotillaRadius.panel, style: .continuous))
                .shadow(color: .black.opacity(0.22), radius: 16, x: 0, y: 8)
        case .plain:
            content
                .background(FlotillaColors.surface)
                .overlay(alignment: .bottom) {
                    Rectangle()
                        .fill(FlotillaColors.separator)
                        .frame(height: FlotillaBorderWidth.hairline)
                }
        case .fullBleed:
            content
                .background(FlotillaColors.surface)
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: FlotillaSpacing.small) {
            Text(file.change.kind.marker)
                .font(FlotillaTypography.caption2.weight(.bold).monospaced())
                .foregroundStyle(file.change.kind.color)
                .accessibilityLabel(file.change.kind.label)

            Text(file.path)
                .font(FlotillaTypography.caption.weight(.medium).monospaced())
                .foregroundStyle(FlotillaColors.textPrimary)
                .lineLimit(1)
                .truncationMode(.head)

            if let previousPath = file.change.previousPath {
                Text("← \(previousPath)")
                    .font(FlotillaTypography.caption2.monospaced())
                    .foregroundStyle(FlotillaColors.textTertiary)
                    .lineLimit(1)
                    .truncationMode(.head)
            }

            Spacer(minLength: FlotillaSpacing.small)

            DiffStatBadge(stat: file.change.stat)

            Button {
                beginDraft(anchor: .file)
            } label: {
                Image(systemName: "text.bubble")
                    .font(.system(size: FlotillaIconSize.xSmall, weight: .semibold))
            }
            .buttonStyle(.plain)
            .foregroundStyle(FlotillaColors.textSecondary)
            .help("Comment on this file")
            .accessibilityLabel("Comment on file")
            .accessibilityIdentifier(AXID.reviewCommentOnFile(file.path))

            Button {
                viewModel.toggleViewed(file)
            } label: {
                Label(
                    file.isViewed ? "Viewed" : "Mark viewed",
                    systemImage: file.isViewed ? "checkmark.square.fill" : "square"
                )
                .font(FlotillaTypography.caption2)
                .labelStyle(.titleAndIcon)
            }
            .buttonStyle(.plain)
            .foregroundStyle(file.isViewed ? FlotillaColors.statusReady : FlotillaColors.textSecondary)
            .accessibilityIdentifier(AXID.reviewFileViewed(file.path))
        }
        .padding(.horizontal, FlotillaSpacing.medium)
        .padding(.vertical, FlotillaSpacing.small)
        .background(FlotillaColors.sidebar)
        .clipShape(RoundedRectangle(cornerRadius: FlotillaRadius.control, style: .continuous))
    }

    // MARK: - Body content

    @ViewBuilder
    private var fileComments: some View {
        let comments = viewModel.fileComments(for: file.path)
        if !comments.isEmpty || isDrafting(.file) {
            VStack(alignment: .leading, spacing: FlotillaSpacing.small) {
                ForEach(comments) { comment in
                    bubble(comment)
                }
                if isDrafting(.file) {
                    editor(title: "Comment on \(file.filename)")
                }
            }
            .padding(FlotillaSpacing.small)
            Divider()
        }
    }

    @ViewBuilder
    private func hunkView(_ hunk: ReviewHunk) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            if style.showHunkHeaders {
                hunkHeader(hunk)
            }

            switch viewModel.diffMode {
            case .inline:
                inlineLines(hunk)
                    .accessibilityIdentifier(AXID.reviewHunkInline.rawValue)
            case .sideBySide:
                sideBySideRows(hunk)
                    .accessibilityIdentifier(AXID.reviewHunkSideBySide.rawValue)
            }
        }
    }

    private func hunkHeader(_ hunk: ReviewHunk) -> some View {
        HStack(spacing: FlotillaSpacing.small) {
            Text("@@ −\(hunk.oldStart),\(hunk.oldCount) +\(hunk.newStart),\(hunk.newCount) @@")
                .font(.system(size: 10, design: .monospaced))
            if !hunk.section.isEmpty {
                Text(hunk.section)
                    .font(.system(size: 10, design: .monospaced))
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .foregroundStyle(FlotillaColors.textTertiary)
        .padding(.horizontal, FlotillaSpacing.medium)
        .padding(.vertical, 3)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(FlotillaColors.surfaceElevated)
    }

    /// One column, in the order git wrote the hunk.
    ///
    /// The content is forced to at least the pane's width so a short line's
    /// added/removed tint still spans the row; it grows past that only when a
    /// line genuinely needs the room, and then the whole hunk scrolls.
    private func inlineLines(_ hunk: ReviewHunk) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(hunk.lines.enumerated()), id: \.offset) { _, line in
                    ReviewDiffLineView(
                        line: line,
                        gutter: .both,
                        path: file.path,
                        onAddComment: { side, number in
                            beginDraft(anchor: .line(side: side, number: number))
                        }
                    )
                    threads(under: line)
                }
            }
            .frame(width: max(availableWidth, inlineIntrinsicWidth), alignment: .leading)
        }
    }

    /// Two columns, the pre-image opposite the post-image.
    ///
    /// The columns scroll together in one horizontal `ScrollView` rather than
    /// each having its own, so a long line on one side cannot slide the two
    /// out of alignment.
    private func sideBySideRows(_ hunk: ReviewHunk) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(ReviewDiff.sideBySideRows(for: hunk).enumerated()), id: \.offset) { _, row in
                    HStack(spacing: 0) {
                        ReviewDiffLineView(
                            line: row.left,
                            gutter: .one(.old),
                            path: file.path,
                            onAddComment: { side, number in
                                beginDraft(anchor: .line(side: side, number: number))
                            }
                        )
                        .frame(width: columnWidth, alignment: .leading)
                        .clipped()

                        Divider()

                        ReviewDiffLineView(
                            line: row.right,
                            gutter: .one(.new),
                            path: file.path,
                            onAddComment: { side, number in
                                beginDraft(anchor: .line(side: side, number: number))
                            }
                        )
                        .frame(width: columnWidth, alignment: .leading)
                        .clipped()
                    }

                    // A thread belongs to a line, not a column, so it spans
                    // the full row underneath both.
                    if let left = row.left { threads(under: left) }
                    if let right = row.right, row.right != row.left { threads(under: right) }
                }
            }
        }
    }

    /// Half the pane each, unless the file's longest line needs more — in
    /// which case both columns grow together and the pane scrolls, so the two
    /// sides never fall out of alignment.
    ///
    /// Computed across the whole file rather than per hunk, so the divider
    /// stays on one vertical line down the file.
    private var columnWidth: CGFloat {
        let half = max(0, availableWidth - ReviewFileSection.dividerWidth) / 2
        return max(half, ReviewDiffMetrics.cellWidth(forCharacters: longestLineLength, gutters: 1))
    }

    private var inlineIntrinsicWidth: CGFloat {
        ReviewDiffMetrics.cellWidth(forCharacters: longestLineLength, gutters: 2)
    }

    /// The longest source line in the file, in characters.
    private var longestLineLength: Int {
        file.hunks.reduce(0) { longest, hunk in
            hunk.lines.reduce(longest) { max($0, $1.text.count) }
        }
    }

    static let dividerWidth: CGFloat = 1

    // MARK: - Threads

    @ViewBuilder
    private func threads(under line: DiffLine) -> some View {
        let side: ReviewSide = line.commentSide == .old ? .old : .new
        if let number = line.number(on: line.commentSide) {
            let comments = viewModel.comments(for: file.path, side: side, line: number)
            let drafting = isDrafting(.line(side: side, number: number))
            if !comments.isEmpty || drafting {
                VStack(alignment: .leading, spacing: FlotillaSpacing.small) {
                    ForEach(comments) { comment in
                        bubble(comment)
                    }
                    if drafting {
                        editor(title: "Comment on line \(number)")
                    }
                }
                .padding(.vertical, FlotillaSpacing.small)
                .padding(.leading, FlotillaSpacing.xxLarge)
                .padding(.trailing, FlotillaSpacing.small)
                .frame(maxWidth: 720, alignment: .leading)
            }
        }
    }

    private func bubble(_ comment: ReviewComment) -> some View {
        ReviewCommentBubble(
            comment: comment,
            onEdit: {
                draftText = comment.body
                draft = ReviewCommentDraft(
                    path: comment.filePath,
                    anchor: comment.anchor,
                    editing: comment.id
                )
            },
            onDelete: { viewModel.deleteComment(comment) }
        )
    }

    private func editor(title: String) -> some View {
        ReviewCommentEditor(
            title: title,
            text: $draftText,
            onSubmit: submitDraft,
            onCancel: cancelDraft
        )
        .frame(maxWidth: 520, alignment: .leading)
    }

    // MARK: - Draft handling

    private func isDrafting(_ anchor: ReviewCommentAnchor) -> Bool {
        draft?.path == file.path && draft?.anchor == anchor
    }

    private func beginDraft(anchor: ReviewCommentAnchor) {
        draftText = ""
        draft = ReviewCommentDraft(path: file.path, anchor: anchor)
    }

    private func submitDraft() {
        guard let draft else { return }
        if let editingID = draft.editing,
           let existing = viewModel.comments.first(where: { $0.id == editingID }) {
            viewModel.updateComment(existing, body: draftText)
        } else {
            viewModel.addComment(path: draft.path, anchor: draft.anchor, body: draftText)
        }
        cancelDraft()
    }

    private func cancelDraft() {
        draft = nil
        draftText = ""
    }

}

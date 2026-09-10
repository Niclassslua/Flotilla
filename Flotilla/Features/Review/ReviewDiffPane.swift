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

    private static let outerPadding = FlotillaSpacing.large

    /// Measured with a `GeometryReader` rather than `.onGeometryChange` so the
    /// content width is right on the *first* layout pass. Side by Side sizes
    /// each column to exactly half of it with no content-based floor, so a
    /// width that is briefly zero would collapse every line to one character;
    /// a `GeometryReader` never hands us that transient zero.
    var body: some View {
        GeometryReader { geometry in
            let contentWidth = max(0, geometry.size.width - Self.outerPadding * 2)

            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(
                        alignment: .leading,
                        spacing: FlotillaSpacing.large,
                        pinnedViews: [.sectionHeaders]
                    ) {
                        ForEach(viewModel.visibleFiles) { file in
                            ReviewFileSection(
                                file: file,
                                viewModel: viewModel,
                                availableWidth: contentWidth,
                                draft: $draft,
                                draftText: $draftText
                            )
                            .id(file.path)
                        }
                    }
                    .padding(Self.outerPadding)
                    .frame(width: geometry.size.width, alignment: .leading)
                }
                .background(FlotillaColors.canvas)
                // In All Files the file list scrolls this pane rather than
                // swapping its contents; in Single File the pane is already
                // just that file, so the scroll is a no-op and harmless.
                .onChange(of: viewModel.selectedPath) { _, newValue in
                    guard let newValue else { return }
                    withAnimation(FlotillaMotion.fast.curve) {
                        proxy.scrollTo(newValue, anchor: .top)
                    }
                }
            }
        }
        .accessibilityIdentifier(AXID.reviewDiffPane.rawValue)
    }
}

/// One file: a sticky header, then its hunks in whichever layout is selected.
struct ReviewFileSection: View {
    let file: ReviewFile
    @Bindable var viewModel: SessionReviewViewModel
    let availableWidth: CGFloat
    @Binding var draft: ReviewCommentDraft?
    @Binding var draftText: String

    var body: some View {
        Section {
            content
        } header: {
            header
        }
        .accessibilityIdentifier(AXID.reviewFileSection(file.path))
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 0) {
            fileComments

            if file.hasNoRenderableDiff {
                Label(file.emptyDiffExplanation, systemImage: "doc.plaintext")
                    .font(FlotillaTypography.caption)
                    .foregroundStyle(FlotillaColors.textTertiary)
                    .padding(FlotillaSpacing.medium)
            } else {
                ForEach(Array(file.hunks.enumerated()), id: \.offset) { index, hunk in
                    if index > 0 {
                        Rectangle()
                            .fill(FlotillaColors.separator)
                            .frame(height: FlotillaBorderWidth.hairline)
                    }
                    hunkView(hunk)
                }
            }
        }
        .background(FlotillaColors.surface)
        .clipShape(
            .rect(
                bottomLeadingRadius: FlotillaRadius.card,
                bottomTrailingRadius: FlotillaRadius.card
            )
        )
        .overlay {
            UnevenRoundedRectangle(bottomLeadingRadius: FlotillaRadius.card, bottomTrailingRadius: FlotillaRadius.card)
                .strokeBorder(FlotillaColors.separator, lineWidth: FlotillaBorderWidth.hairline)
        }
    }

    // MARK: - Header

    /// Sticky while its file scrolls: the change kind, the path with the
    /// filename picked out, line counts, and per-file actions. Its lower
    /// corners are square so it reads as the lid of the card below it.
    private var header: some View {
        HStack(spacing: FlotillaSpacing.small) {
            FileChangeKindBadge(kind: file.change.kind, size: 15)

            HStack(spacing: 0) {
                if let directory = file.directory {
                    Text(directory + "/")
                        .foregroundStyle(FlotillaColors.textTertiary)
                        .layoutPriority(-1)
                }
                Text(file.filename)
                    .foregroundStyle(FlotillaColors.textPrimary)
            }
            .font(FlotillaTypography.caption.weight(.medium).monospaced())
            .lineLimit(1)
            .truncationMode(.head)

            if let previousPath = file.change.previousPath {
                Text("← \(previousPath)")
                    .font(FlotillaTypography.caption2.monospaced())
                    .foregroundStyle(FlotillaColors.textTertiary)
                    .lineLimit(1)
                    .truncationMode(.head)
                    .layoutPriority(-1)
            }

            Spacer(minLength: FlotillaSpacing.small)

            DiffStatBadge(stat: file.change.stat)

            Button {
                beginDraft(anchor: .file)
            } label: {
                Image(systemName: "text.bubble")
                    .font(.system(size: FlotillaIconSize.small, weight: .semibold))
            }
            .buttonStyle(.plain)
            .foregroundStyle(FlotillaColors.textSecondary)
            .help("Comment on this file")
            .accessibilityLabel("Comment on file")
            .accessibilityIdentifier(AXID.reviewCommentOnFile(file.path))

            Button {
                viewModel.toggleViewed(file)
            } label: {
                HStack(spacing: FlotillaSpacing.xSmall) {
                    Image(systemName: file.isViewed ? "checkmark.circle.fill" : "circle")
                        .font(.system(size: FlotillaIconSize.small))
                    Text(file.isViewed ? "Viewed" : "Mark viewed")
                        .font(FlotillaTypography.caption2.weight(.medium))
                }
            }
            .buttonStyle(.plain)
            .foregroundStyle(file.isViewed ? FlotillaColors.statusReady : FlotillaColors.textSecondary)
            .accessibilityIdentifier(AXID.reviewFileViewed(file.path))
        }
        .padding(.horizontal, FlotillaSpacing.medium)
        .padding(.vertical, FlotillaSpacing.small)
        .background(FlotillaColors.surfaceElevated)
        .clipShape(
            .rect(topLeadingRadius: FlotillaRadius.card, topTrailingRadius: FlotillaRadius.card)
        )
        .overlay(alignment: .top) {
            UnevenRoundedRectangle(topLeadingRadius: FlotillaRadius.card, topTrailingRadius: FlotillaRadius.card)
                .strokeBorder(FlotillaColors.separator, lineWidth: FlotillaBorderWidth.hairline)
        }
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
            hunkHeader(hunk)

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

    /// Leads with the section context (usually the enclosing declaration),
    /// which is what actually orients the reader; the raw `@@` line ranges
    /// follow it, dimmed.
    private func hunkHeader(_ hunk: ReviewHunk) -> some View {
        HStack(spacing: FlotillaSpacing.small) {
            if !hunk.section.isEmpty {
                Text(hunk.section)
                    .font(.system(size: 10, weight: .medium, design: .monospaced))
                    .foregroundStyle(FlotillaColors.textSecondary)
                    .lineLimit(1)
            }
            Text("−\(hunk.oldStart),\(hunk.oldCount)  +\(hunk.newStart),\(hunk.newCount)")
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(FlotillaColors.textTertiary)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, FlotillaSpacing.medium)
        .padding(.vertical, 4)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(FlotillaColors.canvas.opacity(0.35))
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

    /// Two columns, the pre-image opposite the post-image, each locked to
    /// exactly half the pane.
    ///
    /// Fixed halves rather than content-width columns: with content width, a
    /// file whose longest line overflowed pushed its own centre divider
    /// wherever that line ended, so stacked files' dividers no longer lined
    /// up. Now the divider is on the same vertical for every file, and a line
    /// too long for its half soft-wraps inside it (see ``ReviewDiffLineView``).
    private func sideBySideRows(_ hunk: ReviewHunk) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(ReviewDiff.sideBySideRows(for: hunk).enumerated()), id: \.offset) { _, row in
                HStack(alignment: .top, spacing: 0) {
                    ReviewDiffLineView(
                        line: row.left,
                        gutter: .one(.old),
                        path: file.path,
                        onAddComment: { side, number in
                            beginDraft(anchor: .line(side: side, number: number))
                        },
                        wrapsText: true
                    )
                    .frame(width: columnWidth, alignment: .topLeading)

                    Divider()

                    ReviewDiffLineView(
                        line: row.right,
                        gutter: .one(.new),
                        path: file.path,
                        onAddComment: { side, number in
                            beginDraft(anchor: .line(side: side, number: number))
                        },
                        wrapsText: true
                    )
                    .frame(width: columnWidth, alignment: .topLeading)
                }

                // A comment sits under the side it was left on: an old-side
                // thread in the left column, a new-side thread in the right.
                // Each slot always occupies a full column so the right thread
                // stays under the right column when the left one is empty.
                HStack(alignment: .top, spacing: 0) {
                    threadColumn(for: row.left, on: .old)
                    threadColumn(for: row.right, on: .new)
                        .padding(.leading, ReviewFileSection.dividerWidth)
                }
            }
        }
        .frame(width: availableWidth, alignment: .leading)
    }

    /// Exactly half the pane, less the centre divider — the same for every
    /// hunk and every file, so the divider is one unbroken vertical line.
    private var columnWidth: CGFloat {
        max(0, availableWidth - ReviewFileSection.dividerWidth) / 2
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

    /// Inline layout: one column, so a thread spans the full width under its
    /// line. Side derives from the line itself.
    @ViewBuilder
    private func threads(under line: DiffLine) -> some View {
        let side: ReviewSide = line.commentSide == .old ? .old : .new
        if let number = line.number(on: line.commentSide) {
            threadStack(side: side, number: number)
                .padding(.leading, FlotillaSpacing.xxLarge)
                .frame(maxWidth: 720, alignment: .leading)
        }
    }

    /// Side by Side: a thread for whichever `DiffSide` this column represents,
    /// so it renders in that column and nowhere else. Always returns a
    /// full-column-width view — a zero-height clear spacer when this side has
    /// no thread — so the sibling column keeps its position.
    @ViewBuilder
    private func threadColumn(for line: DiffLine?, on diffSide: DiffSide) -> some View {
        let side: ReviewSide = diffSide == .old ? .old : .new
        let number = line?.number(on: diffSide)
        let present = number.map { hasThread(side: side, number: $0) } ?? false

        if present, let number {
            threadStack(side: side, number: number)
                .padding(.leading, FlotillaSpacing.large)
                .frame(width: columnWidth, alignment: .topLeading)
        } else {
            Color.clear.frame(width: columnWidth, height: 0)
        }
    }

    private func hasThread(side: ReviewSide, number: Int) -> Bool {
        !viewModel.comments(for: file.path, side: side, line: number).isEmpty
            || isDrafting(.line(side: side, number: number))
    }

    @ViewBuilder
    private func threadStack(side: ReviewSide, number: Int) -> some View {
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
            .padding(.trailing, FlotillaSpacing.small)
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

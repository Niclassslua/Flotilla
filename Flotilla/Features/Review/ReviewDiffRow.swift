import SwiftUI
import AppKit
import GitKit
import SessionKit
import DesignSystem

/// Metrics shared by both diff layouts.
///
/// The text is monospaced, so a line's rendered width is exactly its character
/// count times one advance. That makes it cheap to size a column to its
/// longest line without laying anything out — which is what lets the two
/// side-by-side columns stay equal *and* fill the pane.
enum ReviewDiffMetrics {
    static let fontSize: CGFloat = 11
    static let font = Font.system(size: fontSize, design: .monospaced)
    static let gutterWidth: CGFloat = 34
    static let markerWidth: CGFloat = 12
    static let textLeading: CGFloat = 4
    static let trailingPadding: CGFloat = FlotillaSpacing.medium

    /// One character's advance in the rendered font.
    static let characterWidth: CGFloat = {
        let font = NSFont.monospacedSystemFont(ofSize: fontSize, weight: .regular)
        let advance = font.maximumAdvancement.width
        // `maximumAdvancement` can overstate a proportional fallback; measure
        // a real glyph run and take the smaller, truer value.
        let measured = ("M" as NSString).size(withAttributes: [.font: font]).width
        return measured > 0 ? min(advance, measured) : advance
    }()

    /// Width a line cell needs to show `characters` without clipping.
    static func cellWidth(forCharacters characters: Int, gutters: Int) -> CGFloat {
        CGFloat(gutters) * gutterWidth
            + markerWidth
            + textLeading
            + CGFloat(characters) * characterWidth
            + trailingPadding
    }
}

/// The one primitive both diff layouts are drawn from: a line-number gutter, a
/// marker column, and the source text.
///
/// Written once so that colouring, the hover affordance for adding a comment,
/// and text selection cannot drift between Inline and Side by Side — the two
/// views differ only in how many of these they put in a row.
struct ReviewDiffLineView: View {
    let line: DiffLine?
    /// Which number this cell shows. Inline shows both; each side-by-side
    /// column shows only its own.
    let gutter: Gutter
    let path: String
    let onAddComment: ((ReviewSide, Int) -> Void)?
    /// Side by Side fixes each column at half the pane and soft-wraps a line
    /// too long for it, so the centre divider stays on one vertical line for
    /// every file. Inline keeps the line on one row and scrolls horizontally.
    var wrapsText = false

    @State private var isHovering = false
    @FocusState private var isCommentButtonFocused: Bool

    enum Gutter {
        case both
        case one(DiffSide)

        var count: Int {
            switch self {
            case .both: 2
            case .one: 1
            }
        }
    }

    var body: some View {
        HStack(alignment: wrapsText ? .top : .center, spacing: 0) {
            gutterCells
            marker
            text
            if !wrapsText {
                Spacer(minLength: 0)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(background)
        .contentShape(.rect)
        .onHover { isHovering = $0 }
        .accessibilityIdentifier(identifier)
    }

    // MARK: - Pieces

    /// The add-comment control lives *in the gutter*, not at the trailing edge
    /// of the row.
    ///
    /// A trailing button is unreachable exactly when it is most wanted: a full
    /// line of code consumes the row, leaving the button pushed off the right
    /// of the scrollable content. The gutter is always at the same place,
    /// whatever the line contains.
    @ViewBuilder
    private var gutterCells: some View {
        switch gutter {
        case .both:
            leadingGutterCell(line?.oldNumber)
            gutterCell(line?.newNumber)
        case let .one(side):
            leadingGutterCell(line?.number(on: side))
        }
    }

    private func leadingGutterCell(_ number: Int?) -> some View {
        gutterCell(number)
            .overlay {
                if commentTarget != nil {
                    addCommentButton
                        .focused($isCommentButtonFocused)
                        .opacity(isHovering || isCommentButtonFocused ? 1 : 0)
                }
            }
    }

    private func gutterCell(_ number: Int?) -> some View {
        Text(number.map(String.init) ?? " ")
            .font(ReviewDiffMetrics.font)
            .foregroundStyle(FlotillaColors.textTertiary)
            .frame(width: ReviewDiffMetrics.gutterWidth, alignment: .trailing)
            .accessibilityHidden(true)
    }

    private var marker: some View {
        Text(markerCharacter)
            .font(ReviewDiffMetrics.font)
            .foregroundStyle(foreground)
            .frame(width: ReviewDiffMetrics.markerWidth, alignment: .center)
            .accessibilityHidden(true)
    }

    @ViewBuilder
    private var text: some View {
        // An empty line still needs height, or a blank line in the source
        // collapses the row and the two columns stop lining up.
        let string = line?.text.isEmpty == false ? line!.text : " "
        let base = Text(string)
            .font(ReviewDiffMetrics.font)
            .foregroundStyle(line == nil ? FlotillaColors.textTertiary : foreground)
            .textSelection(.enabled)
            .multilineTextAlignment(.leading)

        if wrapsText {
            // Respect the width the fixed half-column offers and take the
            // vertical space the wrapped line needs, rather than pushing the
            // row wider.
            base
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.leading, ReviewDiffMetrics.textLeading)
                .padding(.vertical, 0.5)
        } else {
            base
                .fixedSize(horizontal: true, vertical: false)
                .padding(.leading, ReviewDiffMetrics.textLeading)
                .padding(.vertical, 0.5)
        }
    }

    private var addCommentButton: some View {
        Button {
            if let target = commentTarget { onAddComment?(target.side, target.line) }
        } label: {
            Image(systemName: "plus")
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(FlotillaColors.accentContent)
                .frame(width: 15, height: 15)
                .background(FlotillaColors.accent, in: RoundedRectangle(cornerRadius: 3, style: .continuous))
        }
        .buttonStyle(.plain)
        .help("Comment on this line")
        .accessibilityLabel("Comment on line")
    }

    // MARK: - Derived

    private var markerCharacter: String {
        switch line?.kind {
        case .added: "+"
        case .removed: "−"
        default: " "
        }
    }

    private var foreground: Color {
        switch line?.kind {
        case .added: FlotillaColors.diffAdded
        case .removed: FlotillaColors.diffRemoved
        default: FlotillaColors.textSecondary
        }
    }

    /// An absent line is the empty half of a side-by-side pair: it is padding,
    /// not content, so it is tinted as neither added nor removed.
    private var background: Color {
        guard let line else { return FlotillaColors.surfaceElevated.opacity(0.35) }
        switch line.kind {
        case .added: return FlotillaColors.diffAddedSurface
        case .removed: return FlotillaColors.diffRemovedSurface
        case .context: return .clear
        }
    }

    /// Where a comment on this line would be anchored, or `nil` if there is no
    /// line here to comment on.
    private var commentTarget: (side: ReviewSide, line: Int)? {
        guard let line, onAddComment != nil else { return nil }
        let side: ReviewSide = line.commentSide == .old ? .old : .new
        guard let number = line.number(on: line.commentSide) else { return nil }
        return (side, number)
    }

    private var identifier: String {
        guard let target = commentTarget else { return "" }
        return AXID.reviewDiffLine(path, side: target.side.rawValue, line: target.line)
    }
}

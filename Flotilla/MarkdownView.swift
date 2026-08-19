import SwiftUI
import MarkdownParser
import DesignSystem

/// SwiftUI view rendering parsed `MarkdownBlock` items styled with Flotilla's design system.
struct MarkdownView: View {
    let blocks: [MarkdownBlock]

    init(blocks: [MarkdownBlock]) {
        self.blocks = blocks
    }

    init(markdown: String) {
        self.blocks = MarkdownDocument.blocks(from: markdown)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: FlotillaSpacing.medium) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                MarkdownBlockView(block: block)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct MarkdownBlockView: View {
    let block: MarkdownBlock

    var body: some View {
        switch block {
        case .heading(let level, let text):
            headingView(level: level, text: text)
        case .paragraph(let text):
            Text(text)
                .font(FlotillaTypography.body)
                .foregroundStyle(FlotillaColors.textPrimary)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        case .codeBlock(let language, let code):
            codeBlockView(language: language, code: code)
        case .listItem(let ordered, let depth, let text):
            listItemView(ordered: ordered, depth: depth, text: text)
        case .blockQuote(let innerBlocks):
            blockQuoteView(innerBlocks)
        case .thematicBreak:
            Divider()
                .padding(.vertical, FlotillaSpacing.small)
        }
    }

    private func headingView(level: Int, text: AttributedString) -> some View {
        let (font, color) = switch level {
        case 1: (Font.title.weight(.bold), FlotillaColors.textPrimary)
        case 2: (Font.title2.weight(.bold), FlotillaColors.textPrimary)
        case 3: (Font.headline.weight(.semibold), FlotillaColors.textPrimary)
        case 4: (Font.subheadline.weight(.semibold), FlotillaColors.textSecondary)
        case 5: (Font.callout.weight(.medium), FlotillaColors.textSecondary)
        default: (Font.caption.weight(.medium), FlotillaColors.textTertiary)
        }

        return Text(text)
            .font(font)
            .foregroundStyle(color)
            .padding(.top, level <= 2 ? FlotillaSpacing.small : 2)
            .textSelection(.enabled)
    }

    private func codeBlockView(language: String?, code: String) -> some View {
        VStack(alignment: .trailing, spacing: 0) {
            if let language {
                Text(language)
                    .font(FlotillaTypography.caption2.monospaced())
                    .foregroundStyle(FlotillaColors.textTertiary)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 2)
                    .background(FlotillaColors.surfaceElevated, in: RoundedRectangle(cornerRadius: 3))
                    .padding(6)
            }
            ScrollView(.horizontal, showsIndicators: true) {
                Text(code)
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(FlotillaColors.textPrimary)
                    .padding(FlotillaSpacing.medium)
                    .textSelection(.enabled)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(FlotillaColors.terminalCanvas, in: RoundedRectangle(cornerRadius: FlotillaRadius.control))
        .overlay {
            RoundedRectangle(cornerRadius: FlotillaRadius.control)
                .strokeBorder(FlotillaColors.separator.opacity(0.5))
        }
    }

    private func listItemView(ordered: Bool, depth: Int, text: AttributedString) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Text(ordered ? "•" : "•")
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(FlotillaColors.accent)
                .frame(width: 12, alignment: .center)
                .padding(.top, 3)

            Text(text)
                .font(FlotillaTypography.body)
                .foregroundStyle(FlotillaColors.textPrimary)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.leading, CGFloat(depth) * 16)
    }

    private func blockQuoteView(_ innerBlocks: [MarkdownBlock]) -> some View {
        HStack(spacing: FlotillaSpacing.medium) {
            RoundedRectangle(cornerRadius: 1)
                .fill(FlotillaColors.accent.opacity(0.6))
                .frame(width: 3)

            VStack(alignment: .leading, spacing: FlotillaSpacing.small) {
                ForEach(Array(innerBlocks.enumerated()), id: \.offset) { _, block in
                    MarkdownBlockView(block: block)
                }
            }
        }
        .padding(.vertical, 2)
    }
}

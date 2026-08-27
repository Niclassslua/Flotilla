import SwiftUI
import Textual
import DesignSystem

/// Renders a Markdown string with Textual's `StructuredText` engine — full GFM
/// support (tables, task lists, fenced code with syntax highlighting) styled to
/// sit close to Flotilla's design system.
struct MarkdownView: View {
    let markdown: String

    init(markdown: String) {
        self.markdown = markdown
    }

    var body: some View {
        StructuredText(markdown: markdown)
            .textual.structuredTextStyle(.gitHub)
            .textual.textSelection(.enabled)
            .font(FlotillaTypography.body)
            .foregroundStyle(FlotillaColors.textPrimary)
            .tint(FlotillaColors.accent)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

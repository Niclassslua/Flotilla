import Foundation
import SwiftUI

public enum MarkdownParserError: Error {
    case invalidMarkdown
}

public struct MarkdownParser {
    private let markdown: String

    public init(_ markdown: String) {
        self.markdown = markdown
    }

    public func attributedString() -> NSAttributedString {
        let wholeRange = NSRange(location: 0, length: max(0, markdown.utf16.count))
        return attributedString(in: wholeRange)
    }

    public func attributedString(in range: NSRange) -> NSAttributedString {
        let nsString = markdown as NSString
        let limitedRange = NSRange(location: min(range.location, nsString.length),
                                   length: max(0, min(range.length, nsString.length - range.location)))
        guard limitedRange.length > 0 else { return NSMutableAttributedString(string: "") }

        let attributed = NSMutableAttributedString(string: nsString.substring(with: limitedRange))
        processRange(in: limitedRange, into: attributed)
        return attributed
    }

    private func processRange(in range: NSRange, into attributed: NSMutableAttributedString) {
        let nsString = markdown as NSString
        let searchRange = NSRange(location: range.location, length: max(0, range.length))
        let text = nsString.substring(with: searchRange)
        let lines = text.components(separatedBy: .newlines)

        var charPos = range.location
        for line in lines {
            let lineLen = max(0, line.utf16.count)
            let lineRange = NSRange(location: charPos, length: lineLen)

            if line.hasPrefix("```") {
                addCodeBlockStyle(to: attributed, range: lineRange)
            } else if line.hasPrefix("# ") || line.hasPrefix("## ") || line.hasPrefix("### ") ||
                      line.hasPrefix("#### ") || line.hasPrefix("##### ") || line.hasPrefix("###### ") {
                let level = countHashes(line)
                addHeaderStyle(to: attributed, range: lineRange, level: level)
            } else if line.hasPrefix("> ") {
                addBlockquoteStyle(to: attributed, range: lineRange)
            } else if line.hasPrefix("- ") || line.hasPrefix("* ") {
                addListItemStyle(to: attributed, range: lineRange, ordered: false)
            } else if line.range(of: "\\d+\\. ", options: .regularExpression) != nil {
                addListItemStyle(to: attributed, range: lineRange, ordered: true)
            } else {
                addDefaultStyle(to: attributed, range: lineRange)
            }

            charPos += lineLen + 1
        }
    }

    private func countHashes(_ line: String) -> Int {
        var count = 0
        for char in line {
            if char == "#" { count += 1 } else { break }
        }
        return min(count, 6)
    }

    private func addCodeBlockStyle(to attributed: NSMutableAttributedString, range: NSRange) {
        attributed.addAttributes([
            .font: Font.system(size: 13, weight: .regular),
            .foregroundColor: Color(red: 0.6, green: 0.6, blue: 0.6),
            .backgroundColor: Color(red: 10/255, green: 10/255, blue: 12/255).opacity(0.3),
            .paragraphStyle: NSMutableParagraphStyle()
        ], range: range)
    }

    private func addHeaderStyle(to attributed: NSMutableAttributedString, range: NSRange, level: Int) {
        let fontSize = CGFloat(max(11, 17 - level))
        let paragraphStyle = NSMutableParagraphStyle()
        paragraphStyle.firstLineHeadIndent = 20
        paragraphStyle.headIndent = CGFloat(level * 20)

        attributed.addAttributes([
            .font: Font.system(size: fontSize, weight: .bold),
            .foregroundColor: Color(red: 1, green: 1, blue: 1),
            .paragraphStyle: paragraphStyle
        ], range: range)
    }

    private func addBlockquoteStyle(to attributed: NSMutableAttributedString, range: NSRange) {
        let paragraphStyle = NSMutableParagraphStyle()
        paragraphStyle.firstLineHeadIndent = 20
        paragraphStyle.headIndent = 20

        attributed.addAttributes([
            .font: Font.system(size: 13, weight: .regular),
            .foregroundColor: Color(red: 0.8, green: 0.8, blue: 0.8),
            .paragraphStyle: paragraphStyle
        ], range: range)
    }

    private func addListItemStyle(to attributed: NSMutableAttributedString, range: NSRange, ordered: Bool) {
        let prefix = ordered ? "1. " : "- "
        let attributedText = NSMutableAttributedString(string: prefix)

        let attrs: [NSAttributedString.Key: Any] = [
            .font: Font.system(size: 13, weight: .regular),
            .foregroundColor: Color(red: 1, green: 1, blue: 1)
        ]

        attributedText.addAttributes(attrs, range: NSRange(location: 0, length: 2))

        let textStart = 2
        let textLen = max(0, range.length - 2)
        if textStart + textLen <= attributedText.length {
            attributedText.addAttributes(attrs, range: NSRange(location: textStart, length: textLen))
        }

        attributed.replaceCharacters(in: range, with: attributedText)
    }

    private func addDefaultStyle(to attributed: NSMutableAttributedString, range: NSRange) {
        attributed.addAttributes([
            .font: Font.system(size: 13),
            .foregroundColor: Color(red: 1, green: 1, blue: 1),
        ], range: range)
    }
}

// MARK: - Public convenience

extension MarkdownParser {
    public static func attributedString(from markdown: String) -> NSAttributedString {
        MarkdownParser(markdown).attributedString()
    }
}
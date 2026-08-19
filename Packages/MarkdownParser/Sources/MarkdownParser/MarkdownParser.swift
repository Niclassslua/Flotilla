import Foundation

public enum MarkdownBlock: Sendable, Equatable {
    case heading(level: Int, AttributedString)
    case paragraph(AttributedString)
    case codeBlock(language: String?, String)
    case listItem(ordered: Bool, depth: Int, AttributedString)
    case blockQuote([MarkdownBlock])
    case thematicBreak
}

public enum MarkdownDocument {
    /// Parses raw markdown into structured blocks, preserving full inline attributes
    /// and correct list item content.
    public static func blocks(from markdown: String) -> [MarkdownBlock] {
        let normalized = markdown
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        let lines = normalized.components(separatedBy: "\n")

        var blocks: [MarkdownBlock] = []
        var i = 0

        while i < lines.count {
            let line = lines[i]
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            // 1. Empty lines
            if trimmed.isEmpty {
                i += 1
                continue
            }

            // 2. Fenced code block (``` or ~~~)
            if trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") {
                let fence = String(trimmed.prefix(3))
                let language = String(trimmed.dropFirst(3)).trimmingCharacters(in: .whitespaces)
                var codeLines: [String] = []
                i += 1
                while i < lines.count {
                    let nextLine = lines[i]
                    let nextTrimmed = nextLine.trimmingCharacters(in: .whitespaces)
                    if nextTrimmed.hasPrefix(fence) {
                        i += 1
                        break
                    }
                    codeLines.append(nextLine)
                    i += 1
                }
                blocks.append(.codeBlock(
                    language: language.isEmpty ? nil : language,
                    codeLines.joined(separator: "\n")
                ))
                continue
            }

            // 3. Thematic break (---, ***, ___)
            if isThematicBreak(trimmed) {
                blocks.append(.thematicBreak)
                i += 1
                continue
            }

            // 4. Headings (# ... ######)
            if let heading = parseHeading(line) {
                blocks.append(heading)
                i += 1
                continue
            }

            // 5. Blockquotes (> ...)
            if trimmed.hasPrefix(">") {
                var quoteLines: [String] = []
                while i < lines.count {
                    let nextLine = lines[i]
                    let nextTrimmed = nextLine.trimmingCharacters(in: .whitespaces)
                    if nextTrimmed.hasPrefix(">") {
                        let stripped: String
                        if nextTrimmed.hasPrefix("> ") {
                            stripped = String(nextTrimmed.dropFirst(2))
                        } else {
                            stripped = String(nextTrimmed.dropFirst(1))
                        }
                        quoteLines.append(stripped)
                        i += 1
                    } else if nextTrimmed.isEmpty {
                        break
                    } else {
                        // Continuation line of blockquote
                        quoteLines.append(nextLine)
                        i += 1
                    }
                }
                let nestedBlocks = Self.blocks(from: quoteLines.joined(separator: "\n"))
                blocks.append(.blockQuote(nestedBlocks))
                continue
            }

            // 6. List items (- , * , + , 1. )
            if let listItem = parseListItem(line) {
                blocks.append(listItem)
                i += 1
                continue
            }

            // 7. Paragraph: accumulate consecutive non-block lines
            var paragraphLines: [String] = []
            while i < lines.count {
                let nextLine = lines[i]
                let nextTrimmed = nextLine.trimmingCharacters(in: .whitespaces)
                if nextTrimmed.isEmpty
                    || nextTrimmed.hasPrefix("```")
                    || nextTrimmed.hasPrefix("~~~")
                    || isThematicBreak(nextTrimmed)
                    || parseHeading(nextLine) != nil
                    || nextTrimmed.hasPrefix(">")
                    || parseListItem(nextLine) != nil {
                    break
                }
                paragraphLines.append(nextLine)
                i += 1
            }

            if !paragraphLines.isEmpty {
                let text = paragraphLines.joined(separator: "\n")
                blocks.append(.paragraph(parseInline(text)))
            }
        }

        return blocks
    }

    private static func parseHeading(_ line: String) -> MarkdownBlock? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.hasPrefix("#") else { return nil }

        var level = 0
        for ch in trimmed {
            if ch == "#" { level += 1 } else { break }
        }

        guard level >= 1 && level <= 6 else { return nil }
        let afterHashes = trimmed.dropFirst(level)
        guard afterHashes.hasPrefix(" ") || afterHashes.isEmpty else { return nil }

        let text = afterHashes.trimmingCharacters(in: .whitespaces)
        return .heading(level: level, parseInline(text))
    }

    private static func parseListItem(_ line: String) -> MarkdownBlock? {
        // Calculate leading space depth
        var leadingSpaces = 0
        for ch in line {
            if ch == " " { leadingSpaces += 1 }
            else if ch == "\t" { leadingSpaces += 4 }
            else { break }
        }
        let depth = leadingSpaces / 2

        let trimmed = line.trimmingCharacters(in: .whitespaces)

        // Unordered: - , * , +
        if trimmed.hasPrefix("- ") || trimmed.hasPrefix("* ") || trimmed.hasPrefix("+ ") {
            let text = String(trimmed.dropFirst(2))
            return .listItem(ordered: false, depth: depth, parseInline(text))
        }

        // Ordered: 1. , 2. , etc.
        if let match = trimmed.range(of: #"^\d+[\.\)]\s+"#, options: .regularExpression) {
            let text = String(trimmed[match.upperBound...])
            return .listItem(ordered: true, depth: depth, parseInline(text))
        }

        return nil
    }

    private static func isThematicBreak(_ line: String) -> Bool {
        let stripped = line.filter { !$0.isWhitespace }
        guard stripped.count >= 3 else { return false }
        let allDash = stripped.allSatisfy { $0 == "-" }
        let allStar = stripped.allSatisfy { $0 == "*" }
        let allUnderscore = stripped.allSatisfy { $0 == "_" }
        return allDash || allStar || allUnderscore
    }

    public static func parseInline(_ text: String) -> AttributedString {
        if let attr = try? AttributedString(markdown: text, options: .init(
            interpretedSyntax: .full,
            failurePolicy: .returnPartiallyParsedIfPossible
        )) {
            return attr
        }
        return AttributedString(text)
    }
}
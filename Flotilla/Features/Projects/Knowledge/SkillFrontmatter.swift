import Foundation

public struct ParsedSkillFrontmatter: Sendable, Hashable {
    public var name: String?
    public var description: String?
    public var version: String?
    public var argumentHint: String?
    public var userInvocable: Bool?
    public var author: String?
    public var license: String?
    public var tags: [String]

    public init(
        name: String? = nil,
        description: String? = nil,
        version: String? = nil,
        argumentHint: String? = nil,
        userInvocable: Bool? = nil,
        author: String? = nil,
        license: String? = nil,
        tags: [String] = []
    ) {
        self.name = name
        self.description = description
        self.version = version
        self.argumentHint = argumentHint
        self.userInvocable = userInvocable
        self.author = author
        self.license = license
        self.tags = tags
    }
}

public enum SkillFrontmatter {
    public static func parse(_ text: String) -> ParsedSkillFrontmatter {
        let normalized = text
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        let lines = normalized.components(separatedBy: "\n")

        guard let first = lines.first, first.trimmingCharacters(in: .whitespaces) == "---" else {
            return ParsedSkillFrontmatter()
        }

        var name: String?
        var description: String?
        var version: String?
        var argumentHint: String?
        var userInvocable: Bool?
        var author: String?
        var license: String?
        var tags: [String] = []

        var i = 1
        var currentKey: String?
        var currentValue: [String] = []

        func flushCurrent() {
            guard let key = currentKey?.lowercased() else { return }
            let combined = currentValue.joined(separator: " ").trimmingCharacters(in: .whitespaces)
            let unquoted = stripQuotes(combined)

            switch key {
            case "name":
                name = unquoted
            case "description":
                description = unquoted
            case "version":
                version = unquoted
            case "argument-hint", "argument_hint", "arguments":
                argumentHint = unquoted
            case "user-invocable", "user_invocable":
                if unquoted.lowercased() == "true" {
                    userInvocable = true
                } else if unquoted.lowercased() == "false" {
                    userInvocable = false
                }
            case "author":
                author = unquoted
            case "license":
                license = unquoted
            case "tags", "keywords", "categories":
                if unquoted.hasPrefix("[") && unquoted.hasSuffix("]") {
                    let inner = unquoted.dropFirst().dropLast()
                    tags = inner.components(separatedBy: ",")
                        .map { stripQuotes($0.trimmingCharacters(in: .whitespaces)) }
                        .filter { !$0.isEmpty }
                } else if !unquoted.isEmpty {
                    tags = currentValue
                        .map { line in
                            var t = line.trimmingCharacters(in: .whitespaces)
                            if t.hasPrefix("-") { t = String(t.dropFirst()).trimmingCharacters(in: .whitespaces) }
                            return stripQuotes(t)
                        }
                        .filter { !$0.isEmpty }
                }
            default:
                break
            }
            currentKey = nil
            currentValue = []
        }

        var hasClosed = false

        while i < lines.count {
            let line = lines[i]
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed == "---" {
                hasClosed = true
                flushCurrent()
                break
            }

            if line.hasPrefix(" ") || line.hasPrefix("\t") || trimmed.hasPrefix("-") {
                if currentKey != nil {
                    currentValue.append(trimmed)
                }
            } else if let colonIdx = line.firstIndex(of: ":") {
                flushCurrent()
                let key = String(line[..<colonIdx]).trimmingCharacters(in: .whitespaces)
                let val = String(line[line.index(after: colonIdx)...]).trimmingCharacters(in: .whitespaces)
                currentKey = key
                if !val.isEmpty && val != ">" && val != ">-" && val != "|" {
                    currentValue.append(val)
                }
            }
            i += 1
        }

        guard hasClosed else { return ParsedSkillFrontmatter() }
        return ParsedSkillFrontmatter(
            name: name,
            description: description,
            version: version,
            argumentHint: argumentHint,
            userInvocable: userInvocable,
            author: author,
            license: license,
            tags: tags
        )
    }

    public static func parseWithFallback(_ text: String, fallbackDirName: String) -> ParsedSkillFrontmatter {
        var parsed = parse(text)
        if parsed.name != nil && parsed.description != nil {
            return parsed
        }

        let normalized = text
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        let lines = normalized.components(separatedBy: "\n")

        var extractedTitle: String?
        var extractedDesc: String?

        var readingParagraph = false
        var paragraphLines: [String] = []

        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty || trimmed == "---" {
                if readingParagraph && !paragraphLines.isEmpty {
                    break
                }
                continue
            }

            if extractedTitle == nil && trimmed.hasPrefix("#") {
                var headerText = trimmed.drop(while: { $0 == "#" }).trimmingCharacters(in: .whitespaces)
                if headerText.hasPrefix("`") && headerText.hasSuffix("`") {
                    headerText = String(headerText.dropFirst().dropLast())
                }
                if !headerText.isEmpty {
                    extractedTitle = headerText
                }
                continue
            }

            if !trimmed.hasPrefix("#") && !trimmed.hasPrefix("```") && !trimmed.hasPrefix("!") {
                readingParagraph = true
                paragraphLines.append(trimmed)
            }
        }

        if !paragraphLines.isEmpty {
            extractedDesc = paragraphLines.joined(separator: " ")
        }

        if parsed.name == nil {
            parsed.name = extractedTitle ?? fallbackDirName
        }
        if parsed.description == nil {
            parsed.description = extractedDesc ?? ""
        }
        return parsed
    }

    private static func stripQuotes(_ s: String) -> String {
        var str = s.trimmingCharacters(in: .whitespaces)
        if (str.hasPrefix("\"") && str.hasSuffix("\"")) || (str.hasPrefix("'") && str.hasSuffix("'")) {
            str = String(str.dropFirst().dropLast())
        }
        return str.trimmingCharacters(in: .whitespaces)
    }
}


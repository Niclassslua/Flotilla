import SwiftUI
import DesignSystem

struct SyntaxHighlightedTextEditor: View {
    @Binding var text: String
    let language: Language
    let font: Font
    let onTextChange: (String) -> Void
    @FocusState private var isFocused: Bool
    @State private var highlightedText: AttributedString = AttributedString()

    init(
        text: Binding<String>,
        language: Language = .plain,
        font: Font = .system(.body, design: .monospaced),
        onTextChange: @escaping (String) -> Void = { _ in }
    ) {
        self._text = text
        self.language = language
        self.font = font
        self.onTextChange = onTextChange
    }

    var body: some View {
        ScrollView {
            ZStack(alignment: .topLeading) {
                Text(highlightedText)
                    .font(font)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 9)
                    .allowsHitTesting(false)

                TextEditor(text: $text)
                    .font(font)
                    .scrollContentBackground(.hidden)
                    .focused($isFocused)
                    .onChange(of: text) { _, newValue in
                        onTextChange(newValue)
                        updateHighlighting()
                    }
                    .frame(minHeight: 200)
                    .background(Color.clear)
                    .colorMultiply(.clear)
            }
        }
        .background(FlotillaColors.terminalCanvas)
        .onAppear {
            updateHighlighting()
        }
    }

    private func updateHighlighting() {
        highlightedText = highlight(text, language: language)
    }

    private func highlight(_ text: String, language: Language) -> AttributedString {
        var result = AttributedString(text)
        let baseFont = NSFont.monospacedSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
        result.font = baseFont
        result.foregroundColor = FlotillaColors.textPrimary

        let patterns = highlightingPatterns(for: language)

        for (pattern, attributes) in patterns {
            let regex = try? NSRegularExpression(pattern: pattern, options: [])
            let nsString = text as NSString
            let matches = regex?.matches(in: text, options: [], range: NSRange(location: 0, length: nsString.length)) ?? []

            for match in matches.reversed() {
                if let attrRange = Range(match.range(at: 0), in: result) {
                    result[attrRange].foregroundColor = attributes.color
                    if let weight = attributes.weight {
                        let newFont: NSFont
                        if weight == .bold {
                            newFont = NSFontManager.shared.convert(baseFont, toHaveTrait: .boldFontMask)
                        } else {
                            newFont = baseFont
                        }
                        result[attrRange].font = newFont
                    }
                }
            }
        }

        return result
    }

    private func highlightingPatterns(for language: Language) -> [(String, (color: Color, weight: NSFont.Weight?))] {
        let keywordColor = FlotillaColors.accent
        let commentColor = FlotillaColors.textTertiary
        let stringColor = FlotillaColors.success
        let numberColor = FlotillaColors.statusReady
        let typeColor = FlotillaColors.statusReady
        let functionColor = FlotillaColors.warning

        switch language {
        case .swift:
            return [
                (pattern: #"\b(func|let|var|struct|class|enum|protocol|extension|import|if|else|for|while|switch|case|default|guard|defer|return|throw|try|catch|async|await|actor|typealias|associatedtype|init|deinit|subscript|operator|precedencegroup|infix|prefix|postfix|public|private|internal|fileprivate|open|final|override|static|mutating|nonmutating|convenience|required|weak|unowned|lazy|@objc|@IBOutlet|@IBAction|@escaping|@autoclosure|@discardableResult|@available|@frozen|@unknown|default|self|Self|super|nil|true|false)\b"#, (keywordColor, .bold)),
                (pattern: #"(//.*|/\*[\s\S]*?\*/)"#, (commentColor, nil)),
                (pattern: #""([^"\\]|\\.)*""#, (stringColor, nil)),
                (pattern: #"\b\d+(\.\d+)?\b"#, (numberColor, nil)),
            ]
        case .javascript, .typescript:
            return [
                (pattern: #"\b(const|let|var|function|async|await|return|if|else|for|while|switch|case|default|break|continue|try|catch|finally|throw|class|extends|implements|interface|type|enum|import|export|from|as|new|this|super|static|get|set|public|private|protected|readonly|abstract|declare|namespace|module|global|typeof|instanceof|in|of|void|null|undefined|true|false)\b"#, (keywordColor, .bold)),
                (pattern: #"(//.*|/\*[\s\S]*?\*/)"#, (commentColor, nil)),
                (pattern: #""([^"\\]|\\.)*""#, (stringColor, nil)),
                (pattern: #"'([^'\\]|\\.)*'"#, (stringColor, nil)),
                (pattern: #"`([^`\\]|\\.)*`"#, (stringColor, nil)),
                (pattern: #"\b\d+(\.\d+)?\b"#, (numberColor, nil)),
            ]
        case .python:
            return [
                (pattern: #"\b(def|class|if|elif|else|for|while|try|except|finally|raise|with|as|import|from|return|yield|lambda|async|await|pass|break|continue|del|global|nonlocal|assert|is|in|not|and|or|True|False|None|self|cls)\b"#, (keywordColor, .bold)),
                (pattern: #"(#.*)"#, (commentColor, nil)),
                (pattern: #""""[\s\S]*?""""#, (stringColor, nil)),
                (pattern: #"'''[\s\S]*?'''"#, (stringColor, nil)),
                (pattern: #""([^"\\]|\\.)*""#, (stringColor, nil)),
                (pattern: #"'([^'\\]|\\.)*'"#, (stringColor, nil)),
                (pattern: #"\b\d+(\.\d+)?\b"#, (numberColor, nil)),
            ]
        case .rust:
            return [
                (pattern: #"\b(fn|let|mut|const|static|struct|enum|trait|impl|mod|use|pub|crate|super|self|Self|if|else|match|loop|while|for|break|continue|return|async|await|move|ref|box|type|where|dyn|trait|auto|union|extern|crate|super|self)\b"#, (keywordColor, .bold)),
                (pattern: #"(//.*|/\*[\s\S]*?\*/)"#, (commentColor, nil)),
                (pattern: "r#*\"\"([^\"#]*)\"\"#*", (stringColor, nil)),
                (pattern: #"r#*'([^'#]*)'#*"#, (stringColor, nil)),
                (pattern: #"\b\d+(\.\d+)?\b"#, (numberColor, nil)),
            ]
        case .go:
            return [
                (pattern: #"\b(func|var|const|type|struct|interface|map|chan|make|new|if|else|for|range|switch|case|default|break|continue|return|go|defer|select|fallthrough|package|import)\b"#, (keywordColor, .bold)),
                (pattern: #"(//.*|/\*[\s\S]*?\*/)"#, (commentColor, nil)),
                (pattern: #""([^"\\]|\\.)*""#, (stringColor, nil)),
                (pattern: #"`([^`\\]|\\.)*`"#, (stringColor, nil)),
                (pattern: #"\b\d+(\.\d+)?\b"#, (numberColor, nil)),
            ]
        case .json:
            return [
                (pattern: #""[^"]*"\s*:"#, (keywordColor, .bold)),
                (pattern: #""([^"\\]|\\.)*""#, (stringColor, nil)),
                (pattern: #"\b(true|false|null)\b"#, (numberColor, .bold)),
                (pattern: #"\b\d+(\.\d+)?\b"#, (numberColor, nil)),
            ]
        case .yaml:
            return [
                (pattern: #"^\s*\w+:"#, (keywordColor, .bold)),
                (pattern: #"(#.*)"#, (commentColor, nil)),
                (pattern: #""([^"\\]|\\.)*""#, (stringColor, nil)),
                (pattern: #"'([^'\\]|\\.)*'"#, (stringColor, nil)),
            ]
        case .markdown:
            return [
                (pattern: #"^#{1,6}\s+.*$"#, (keywordColor, .bold)),
                (pattern: #"\*\*([^*]+)\*\*"#, (keywordColor, .bold)),
                (pattern: #"\*([^*]+)\*"#, (keywordColor, nil)),
                (pattern: #"`([^`]+)`"#, (stringColor, nil)),
                (pattern: #"```[\s\S]*?```"#, (stringColor, nil)),
                (pattern: #"\[([^\]]+)\]\([^)]+\)"#, (numberColor, nil)),
            ]
        case .html:
            return [
                (pattern: #"</?[a-z][a-z0-9]*\b[^>]*>"#, (keywordColor, .bold)),
                (pattern: #"\w+="([^"]*)""#, (stringColor, nil)),
                (pattern: #"<!--[\s\S]*?-->"#, (commentColor, nil)),
            ]
        case .css:
            return [
                (pattern: #"[.#][\w-]+"#, (keywordColor, .bold)),
                (pattern: #"\b(color|background|border|margin|padding|font|display|position|top|right|bottom|left|width|height|flex|grid|align|justify)\s*:"#, (typeColor, .bold)),
                (pattern: #"/\*[\s\S]*?\*/"#, (commentColor, nil)),
                (pattern: #"#[0-9a-fA-F]{3,8}\b"#, (numberColor, nil)),
            ]
        case .shell:
            return [
                (pattern: #"\b(if|then|else|elif|fi|for|while|do|done|case|esac|function|return|exit|break|continue|local|declare|readonly|export|source|alias|unset|set|shift|trap|eval|exec|cd|pwd|ls|cat|grep|sed|awk|find|xargs|echo|printf|read|test|true|false)\b"#, (keywordColor, .bold)),
                (pattern: #"(#.*)"#, (commentColor, nil)),
                (pattern: #""([^"\\]|\\.)*""#, (stringColor, nil)),
                (pattern: #"'([^'\\]|\\.)*'"#, (stringColor, nil)),
                (pattern: #"\$\w+"#, (functionColor, nil)),
            ]
        case .sql:
            return [
                (pattern: #"\b(SELECT|FROM|WHERE|INSERT|UPDATE|DELETE|CREATE|DROP|ALTER|TABLE|INDEX|VIEW|DATABASE|JOIN|INNER|LEFT|RIGHT|OUTER|ON|GROUP|BY|ORDER|HAVING|LIMIT|OFFSET|UNION|DISTINCT|AS|AND|OR|NOT|IN|LIKE|BETWEEN|IS|NULL|TRUE|FALSE|PRIMARY|KEY|FOREIGN|REFERENCES|UNIQUE|CHECK|DEFAULT|AUTO_INCREMENT|VALUES|SET|BEGIN|COMMIT|ROLLBACK|TRANSACTION)\b"#, (keywordColor, .bold)),
                (pattern: #"(--.*)"#, (commentColor, nil)),
                (pattern: #"/\*[\s\S]*?\*/"#, (commentColor, nil)),
                (pattern: #"'([^'\\]|\\.)*'"#, (stringColor, nil)),
            ]
        case .dockerfile:
            return [
                (pattern: #"^(FROM|RUN|CMD|ENTRYPOINT|COPY|ADD|ENV|EXPOSE|VOLUME|WORKDIR|USER|ARG|LABEL|MAINTAINER|ONBUILD|STOPSIGNAL|HEALTHCHECK|SHELL)\b"#, (keywordColor, .bold)),
                (pattern: #"(#.*)"#, (commentColor, nil)),
            ]
        case .toml:
            return [
                (pattern: #"^\s*[\w-]+\s*="#, (keywordColor, .bold)),
                (pattern: #"(#.*)"#, (commentColor, nil)),
                (pattern: #""([^"\\]|\\.)*""#, (stringColor, nil)),
            ]
        case .xml:
            return [
                (pattern: #"</?[\w:]+\b[^>]*>"#, (keywordColor, .bold)),
                (pattern: #"\w+="([^"]*)""#, (stringColor, nil)),
                (pattern: #"<!--[\s\S]*?-->"#, (commentColor, nil)),
            ]
        case .plain:
            return []
        }
    }

    enum Language {
        case swift, javascript, typescript, python, rust, go
        case json, yaml, markdown, html, css, shell, sql
        case dockerfile, toml, xml, plain

        static func from(url: URL) -> Language {
            let ext = url.pathExtension.lowercased()
            let name = url.lastPathComponent.lowercased()

            switch (ext, name) {
            case ("swift", _): return .swift
            case ("js", _), ("jsx", _), ("mjs", _), ("cjs", _): return .javascript
            case ("ts", _), ("tsx", _), ("mts", _), ("cts", _): return .typescript
            case ("py", _), ("pyw", _), ("pyi", _): return .python
            case ("rs", _), ("rlib", _): return .rust
            case ("go", _): return .go
            case ("json", _), ("jsonc", _), ("json5", _): return .json
            case ("yaml", _), ("yml", _): return .yaml
            case ("md", _), ("markdown", _), ("mdx", _): return .markdown
            case ("html", _), ("htm", _), ("xhtml", _): return .html
            case ("css", _), ("scss", _), ("sass", _), ("less", _), ("styl", _): return .css
            case ("sh", _), ("bash", _), ("zsh", _), ("fish", _): return .shell
            case ("sql", _): return .sql
            case ("dockerfile", _), ("dockerfile.dev", _), ("dockerfile.prod", _): return .dockerfile
            case ("toml", _): return .toml
            case ("xml", _), ("plist", _), ("svg", _): return .xml
            default: return .plain
            }
        }
    }
}
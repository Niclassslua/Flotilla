import SwiftUI
import DesignSystem

/// Material-style icon descriptor for files and directories matching VS Code's Material Icon Theme.
public enum MaterialIconKind: Sendable, Hashable {
    /// Rendered as a colored badge with sharp typography (e.g. TS, JS, M↓, {}, $_, C++, </>)
    case badge(text: String, background: Color, foreground: Color = .white, fontSize: CGFloat = 8.5)
    /// Rendered as an SF Symbol with Material Icon Theme color palette
    case symbol(name: String, color: Color)
    /// Folder with custom tint and optional glyph badge
    case folder(color: Color, glyph: String? = nil, isExpanded: Bool = false)
}

public struct MaterialIconProvider {
    public static func icon(for url: URL, isDirectory: Bool = false, isExpanded: Bool = false) -> MaterialIconKind {
        if isDirectory {
            return folderIcon(for: url, isExpanded: isExpanded)
        }
        return fileIcon(for: url)
    }

    // MARK: - Folder Icons

    public static func folderIcon(for url: URL, isExpanded: Bool = false) -> MaterialIconKind {
        let name = url.lastPathComponent.lowercased()

        switch name {
        case ".git", ".github":
            return .folder(color: Color(hex: 0xF4511E), glyph: "arrow.triangle.branch", isExpanded: isExpanded)
        case "src", "source", "sources", "app", "lib", "libs":
            return .folder(color: Color(hex: 0x42A5F5), glyph: "chevron.left.forwardslash.chevron.right", isExpanded: isExpanded)
        case "test", "tests", "spec", "specs", "__tests__", "flotillaunittests", "flotillauitests":
            return .folder(color: Color(hex: 0x4CAF50), glyph: "flask.fill", isExpanded: isExpanded)
        case "dist", "build", "out", "target", ".build", "deriveddata":
            return .folder(color: Color(hex: 0x8D6E63), glyph: "shippingbox.fill", isExpanded: isExpanded)
        case "node_modules":
            return .folder(color: Color(hex: 0x8BC34A), glyph: "hexagon.fill", isExpanded: isExpanded)
        case "packages":
            return .folder(color: Color(hex: 0xAB47BC), glyph: "cube.box.fill", isExpanded: isExpanded)
        case "assets", "images", "img", "media", "icons", "resources":
            return .folder(color: Color(hex: 0xEC407A), glyph: "photo.fill", isExpanded: isExpanded)
        case "docs", "doc", "documentation":
            return .folder(color: Color(hex: 0x26C6DA), glyph: "book.fill", isExpanded: isExpanded)
        case "config", "configs", ".config":
            return .folder(color: Color(hex: 0x78909C), glyph: "gearshape.fill", isExpanded: isExpanded)
        case "scripts", "bin", "tools":
            return .folder(color: Color(hex: 0x00897B), glyph: "terminal.fill", isExpanded: isExpanded)
        case "hooks":
            return .folder(color: Color(hex: 0x009688), glyph: "link", isExpanded: isExpanded)
        case "components", "views", "ui":
            return .folder(color: Color(hex: 0x00BCD4), glyph: "square.grid.2x2.fill", isExpanded: isExpanded)
        default:
            // Default warm golden folder
            return .folder(color: Color(hex: 0xE5A93C), isExpanded: isExpanded)
        }
    }

    // MARK: - File Icons

    public static func fileIcon(for url: URL) -> MaterialIconKind {
        let name = url.lastPathComponent.lowercased()
        let ext = url.pathExtension.lowercased()

        // 1. Exact Filename Matches
        switch name {
        case "package.json":
            return .badge(text: "npm", background: Color(hex: 0xCB3837), foreground: .white, fontSize: 7.5)
        case "package-lock.json", "yarn.lock", "pnpm-lock.yaml", "bun.lockb", "cargo.lock", "gemfile.lock", "composer.lock", "podfile.lock", "package.resolved":
            return .symbol(name: "lock.fill", color: Color(hex: 0xFDD835))
        case "dockerfile", "dockerfile.dev", "dockerfile.prod", "docker-compose.yml", "docker-compose.yaml":
            return .symbol(name: "shippingbox.fill", color: Color(hex: 0x2496ED))
        case "makefile", "gnumakefile", "makefile.am", "makefile.in":
            return .badge(text: "MAKE", background: Color(hex: 0x6D4C41), foreground: .white, fontSize: 6.5)
        case "license", "license.md", "license.txt", "copying":
            return .symbol(name: "doc.plaintext.fill", color: Color(hex: 0xFFD54F))
        case "readme.md", "readme", "readme.txt":
            return .badge(text: "M↓", background: Color(hex: 0x1E88E5), foreground: .white, fontSize: 8.5)
        case ".gitignore", ".gitattributes", ".gitmodules", ".gitconfig":
            return .symbol(name: "arrow.triangle.branch", color: Color(hex: 0xF4511E))
        case ".env", ".env.local", ".env.development", ".env.production", ".env.example", ".env.test":
            return .symbol(name: "key.fill", color: Color(hex: 0xFDD835))
        case "tsconfig.json", "jsconfig.json":
            return .badge(text: "TS", background: Color(hex: 0x3178C6), foreground: .white, fontSize: 8.5)
        case "project.yml", "project.yaml":
            return .badge(text: "XCG", background: Color(hex: 0x7E57C2), foreground: .white, fontSize: 7)
        case "package.swift":
            return .symbol(name: "swift", color: Color(hex: 0xF05138))
        default:
            break
        }

        // 2. Extension Matches
        switch ext {
        case "swift":
            return .symbol(name: "swift", color: Color(hex: 0xF05138))
        case "ts", "mts", "cts":
            return .badge(text: "TS", background: Color(hex: 0x3178C6), foreground: .white, fontSize: 8.5)
        case "tsx":
            return .badge(text: "TSX", background: Color(hex: 0x0288D1), foreground: .white, fontSize: 7.5)
        case "js", "mjs", "cjs":
            return .badge(text: "JS", background: Color(hex: 0xF7DF1E), foreground: Color(hex: 0x1A1A1A), fontSize: 8.5)
        case "jsx":
            return .badge(text: "JSX", background: Color(hex: 0x00BCD4), foreground: .white, fontSize: 7.5)
        case "py", "pyw", "pyi", "ipynb":
            return .badge(text: "PY", background: Color(hex: 0x3776AB), foreground: Color(hex: 0xFFD43B), fontSize: 8.5)
        case "rs", "rlib":
            return .symbol(name: "gearshape.fill", color: Color(hex: 0xDEA584))
        case "go":
            return .badge(text: "GO", background: Color(hex: 0x00ADD8), foreground: .white, fontSize: 8.5)
        case "c", "h":
            return .badge(text: "C", background: Color(hex: 0x5C6BC0), foreground: .white, fontSize: 9)
        case "cpp", "hpp", "cc", "cxx", "hh", "hxx":
            return .badge(text: "C++", background: Color(hex: 0x1976D2), foreground: .white, fontSize: 7.5)
        case "cs":
            return .badge(text: "C#", background: Color(hex: 0x7E57C2), foreground: .white, fontSize: 8.5)
        case "java", "class", "jar":
            return .badge(text: "JAVA", background: Color(hex: 0xE53935), foreground: .white, fontSize: 6.5)
        case "kt", "kts":
            return .badge(text: "KT", background: Color(hex: 0x7F52FF), foreground: .white, fontSize: 8.5)
        case "html", "htm", "xhtml":
            return .badge(text: "</>", background: Color(hex: 0xE44D26), foreground: .white, fontSize: 7.5)
        case "css":
            return .badge(text: "#", background: Color(hex: 0x1572B6), foreground: .white, fontSize: 10)
        case "scss", "sass", "less", "styl":
            return .badge(text: "SCSS", background: Color(hex: 0xCF649A), foreground: .white, fontSize: 6.5)
        case "json", "jsonc", "json5":
            return .badge(text: "{ }", background: Color(hex: 0xFBC02D), foreground: Color(hex: 0x212121), fontSize: 8)
        case "yaml", "yml":
            return .badge(text: "YML", background: Color(hex: 0xEF5350), foreground: .white, fontSize: 7)
        case "toml":
            return .badge(text: "TOML", background: Color(hex: 0x8D6E63), foreground: .white, fontSize: 6.5)
        case "md", "markdown", "mdx":
            return .badge(text: "M↓", background: Color(hex: 0x42A5F5), foreground: .white, fontSize: 8.5)
        case "sh", "bash", "zsh", "fish":
            return .badge(text: "$_", background: Color(hex: 0x43A047), foreground: .white, fontSize: 8.5)
        case "sql":
            return .symbol(name: "cylinder.split.1x2.fill", color: Color(hex: 0xFB8C00))
        case "php", "phtml":
            return .badge(text: "PHP", background: Color(hex: 0x777BB4), foreground: .white, fontSize: 7)
        case "rb", "rake", "gemspec":
            return .symbol(name: "suit.diamond.fill", color: Color(hex: 0xCC342D))
        case "lua":
            return .badge(text: "LUA", background: Color(hex: 0x000080), foreground: .white, fontSize: 7)
        case "dart":
            return .badge(text: "DART", background: Color(hex: 0x0175C2), foreground: .white, fontSize: 6.5)
        case "zig":
            return .badge(text: "ZIG", background: Color(hex: 0xF7A41D), foreground: .white, fontSize: 7.5)
        case "vue":
            return .badge(text: "VUE", background: Color(hex: 0x42B883), foreground: .white, fontSize: 7)
        case "svelte":
            return .badge(text: "SVT", background: Color(hex: 0xFF3E00), foreground: .white, fontSize: 7)
        case "graphql", "gql":
            return .symbol(name: "hexagon.fill", color: Color(hex: 0xE10098))
        case "proto":
            return .badge(text: "PBF", background: Color(hex: 0x78909C), foreground: .white, fontSize: 7)
        case "xml", "plist", "svg":
            return .symbol(name: "chevron.left.forwardslash.chevron.right", color: Color(hex: 0x26A69A))
        case "png", "jpg", "jpeg", "gif", "webp", "ico", "bmp", "tiff", "heic":
            return .symbol(name: "photo.fill", color: Color(hex: 0xAB47BC))
        case "mp4", "mov", "mkv", "webm", "avi", "flv":
            return .symbol(name: "film.fill", color: Color(hex: 0xEC407A))
        case "mp3", "wav", "flac", "m4a", "aac", "ogg":
            return .symbol(name: "music.note", color: Color(hex: 0x26C6DA))
        case "zip", "tar", "gz", "bz2", "xz", "7z", "rar":
            return .symbol(name: "archivebox.fill", color: Color(hex: 0xFFA000))
        case "pdf":
            return .symbol(name: "doc.fill", color: Color(hex: 0xE53935))
        case "txt", "log":
            return .symbol(name: "doc.text.fill", color: Color(hex: 0x90A4AE))
        default:
            return .symbol(name: "doc.fill", color: Color(hex: 0x78909C))
        }
    }
}

/// SwiftUI View rendering Material Icon Theme styled file and folder icons.
public struct MaterialFileIcon: View {
    public let kind: MaterialIconKind
    public let size: CGFloat

    public init(kind: MaterialIconKind, size: CGFloat = 16) {
        self.kind = kind
        self.size = size
    }

    public init(url: URL, isDirectory: Bool = false, isExpanded: Bool = false, size: CGFloat = 16) {
        self.kind = MaterialIconProvider.icon(for: url, isDirectory: isDirectory, isExpanded: isExpanded)
        self.size = size
    }

    init(node: FileNode, isExpanded: Bool = false, size: CGFloat = 16) {
        self.kind = MaterialIconProvider.icon(for: node.url, isDirectory: node.isDirectory, isExpanded: isExpanded)
        self.size = size
    }

    public var body: some View {
        ZStack {
            switch kind {
            case .badge(let text, let background, let foreground, let fontSize):
                badgeView(text: text, background: background, foreground: foreground, fontSize: fontSize)
            case .symbol(let name, let color):
                symbolView(name: name, color: color)
            case .folder(let color, let glyph, let isExpanded):
                folderView(color: color, glyph: glyph, isExpanded: isExpanded)
            }
        }
        .frame(width: size, height: size)
    }

    @ViewBuilder
    private func badgeView(text: String, background: Color, foreground: Color, fontSize: CGFloat) -> some View {
        let scale = size / 16.0
        RoundedRectangle(cornerRadius: 3.0 * scale, style: .continuous)
            .fill(background)
            .overlay {
                Text(text)
                    .font(.system(size: fontSize * scale, weight: .bold, design: .rounded))
                    .foregroundStyle(foreground)
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
                    .padding(.horizontal, 1 * scale)
            }
    }

    @ViewBuilder
    private func symbolView(name: String, color: Color) -> some View {
        Image(systemName: name)
            .resizable()
            .scaledToFit()
            .foregroundStyle(color)
            .frame(width: size * 0.9, height: size * 0.9)
    }

    @ViewBuilder
    private func folderView(color: Color, glyph: String?, isExpanded: Bool) -> some View {
        ZStack {
            Image(systemName: isExpanded ? "folder.fill" : "folder.fill")
                .resizable()
                .scaledToFit()
                .foregroundStyle(color)

            if let glyph {
                Image(systemName: glyph)
                    .font(.system(size: size * 0.38, weight: .bold))
                    .foregroundStyle(.white.opacity(0.92))
                    .offset(y: size * 0.08)
            }
        }
        .frame(width: size, height: size)
    }
}

// MARK: - Color Extension

private extension Color {
    init(hex: UInt32, alpha: Double = 1.0) {
        let r = Double((hex >> 16) & 0xFF) / 255.0
        let g = Double((hex >> 8) & 0xFF) / 255.0
        let b = Double(hex & 0xFF) / 255.0
        self.init(.sRGB, red: r, green: g, blue: b, opacity: alpha)
    }
}

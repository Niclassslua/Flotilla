import SwiftUI
import AppKit
import DesignSystem

/// High-performance loader and cache for authentic VS Code Material Icon Theme SVG assets.
public final class MaterialIconCache: @unchecked Sendable {
    public static let shared = MaterialIconCache()

    private let cache = NSCache<NSString, NSImage>()

    private init() {
        cache.countLimit = 250
    }

    public func image(named name: String) -> NSImage? {
        let key = name as NSString
        if let cached = cache.object(forKey: key) {
            return cached
        }

        // 1. Antigravity / Gemini official brand logo (ProviderLogoAntigravity)
        if name == "gemini" || name == "antigravity" || name == "agy" {
            if let antigravityAsset = ProviderLogoAsset.antigravity.nsImage {
                cache.setObject(antigravityAsset, forKey: key)
                return antigravityAsset
            }
        }
        if name == "claude" {
            if let claudeAsset = ProviderLogoAsset.claude.nsImage {
                cache.setObject(claudeAsset, forKey: key)
                return claudeAsset
            }
        }
        if name == "codex" || name == "openai" {
            if let codexAsset = ProviderLogoAsset.codex.nsImage {
                cache.setObject(codexAsset, forKey: key)
                return codexAsset
            }
        }
        if name == "opencode" {
            if let openCodeAsset = ProviderLogoAsset.openCode.nsImage {
                cache.setObject(openCodeAsset, forKey: key)
                return openCodeAsset
            }
        }
        if name == "cursor" {
            if let cursorAsset = ProviderLogoAsset.cursor.nsImage {
                cache.setObject(cursorAsset, forKey: key)
                return cursorAsset
            }
        }

        // 2. Check SVG files in bundle / development paths
        let lookupNames: [String] = (name == "folder-open" || name == "folder") ? ["folder", "folder-base", name] : [name]
        var candidateURLs: [URL] = []
        for n in lookupNames {
            if let url = Bundle.main.url(forResource: n, withExtension: "svg", subdirectory: "MaterialIcons") {
                candidateURLs.append(url)
            }
            if let url = Bundle.main.url(forResource: n, withExtension: "svg") {
                candidateURLs.append(url)
            }
            candidateURLs.append(Bundle.main.bundleURL.appendingPathComponent("Contents/Resources/\(n).svg"))
            candidateURLs.append(Bundle.main.bundleURL.appendingPathComponent("Contents/Resources/MaterialIcons/\(n).svg"))
            candidateURLs.append(
                URL(fileURLWithPath: #file)
                    .deletingLastPathComponent()
                    .appendingPathComponent("Resources/MaterialIcons/\(n).svg")
            )
        }

        for url in candidateURLs {
            if FileManager.default.fileExists(atPath: url.path),
               let image = NSImage(contentsOf: url) {
                cache.setObject(image, forKey: key)
                return image
            }
        }

        return nil
    }
}

/// Provider mapping file URLs and folder structures to authentic Material Icon Theme icon names.
public struct MaterialIconProvider {

    public static func iconName(for url: URL, isDirectory: Bool = false, isExpanded: Bool = false) -> String {
        if isDirectory {
            return folderIconName(for: url, isExpanded: isExpanded)
        }
        return fileIconName(for: url)
    }

    // MARK: - Folder Icons

    public static func folderIconName(for url: URL, isExpanded: Bool = false) -> String {
        let name = url.lastPathComponent.lowercased()

        if name == ".gemini" || name == "gemini" || name == ".antigravity" || name == "antigravity" || name.contains("gemini") || name.contains("antigravity") {
            return "gemini"
        }
        if name == ".claude" || name == "claude" || name.contains("claude") {
            return "claude"
        }
        if name == ".cursor" || name == "cursor" || name.contains("cursor") {
            return "cursor"
        }
        if name == ".agents" || name == "agents" || name == ".skills" || name == "skills" || name.contains("agent") || name.contains("skill") {
            return "robot"
        }

        switch name {
        case ".git":
            return "folder-git"
        case ".github":
            return "folder-github"
        case ".gitea", "gitea":
            return "folder-gitea"
        case ".idea", "idea":
            return "folder-intellij"
        case ".cache", "cache", "dist", "build", "out", "target", ".build", "deriveddata":
            return "folder-dist"
        case "node_modules", ".pnpm-store", "pnpm":
            return "folder-node"
        case "packages", "pkg", "pkgs":
            return "folder-packages"
        case "attachments", "attachment":
            return "folder-attachment"
        case "assets", "images", "img", "media", "icons", "resources", "files", "file":
            return "folder-images"
        case "docs", "doc", "documentation":
            return "folder-docs"
        case "logs", "log":
            return "folder-log"
        case "profiles", "profile", "config", "configs", ".config", "settings":
            return "folder-config"
        case "perf-debug", "debug", "perf":
            return "folder-debug"
        case "security", "secure", "sec", "auth":
            return "folder-secure"
        case "workflows", "workflow", "tasks", "task":
            return "folder-workflows"
        case "scripts", "bin", "tools":
            return "folder-scripts"
        case "hooks":
            return "folder-hook"
        case "components":
            return "folder-components"
        case "views", "ui":
            return "folder-views"
        case "src", "source", "sources", "app", "lib", "libs", "index":
            return "folder-src"
        case "test", "tests", "spec", "specs", "__tests__", "flotillaunittests", "flotillauitests":
            return "folder-test"
        default:
            return "folder"
        }
    }

    // MARK: - File Icons

    public static func fileIconName(for url: URL) -> String {
        let name = url.lastPathComponent.lowercased()
        let path = url.path.lowercased()
        let ext = url.pathExtension.lowercased()

        // 1. AI Rules, Providers, & Dot Files (Exact, Prefix, & Path Matches)
        if name.contains("gemini") || name.contains("antigravity") || path.contains("/.gemini/") || path.contains("/.antigravity/") {
            return "gemini"
        }
        if name.contains("claude") || path.contains("/.claude/") {
            return "claude"
        }
        if name.contains("cursor") || path.contains("/.cursor/") {
            return "cursor"
        }
        if name.contains("copilot") {
            return "copilot"
        }
        if name == "agents.md" || name == "agent.md" || name == "skill.md" || name == "skills.md" || name.hasPrefix(".agent") || path.contains("/.agents/") {
            return "robot"
        }

        // 2. Exact Filename Matches
        switch name {
        // Package & Project Configs
        case "package.json":
            return "npm"
        case "package-lock.json", "yarn.lock", "pnpm-lock.yaml", "bun.lockb", "cargo.lock", "gemfile.lock", "composer.lock", "podfile.lock", "package.resolved":
            return "lock"
        case "dockerfile", "dockerfile.dev", "dockerfile.prod", "docker-compose.yml", "docker-compose.yaml", ".dockerignore":
            return "docker"
        case "makefile", "gnumakefile", "makefile.am", "makefile.in":
            return "settings"
        case "readme.md", "readme", "readme.txt":
            return "markdown"
        case ".gitignore", ".gitattributes", ".gitmodules", ".gitconfig":
            return "git"
        case ".env", ".env.local", ".env.development", ".env.production", ".env.example", ".env.test":
            return "tune"
        case "tsconfig.json", "jsconfig.json":
            return "typescript"
        case "project.yml", "project.yaml":
            return "visualstudio"
        case "package.swift":
            return "swift"
        case "cargo.toml":
            return "cargo"
        case "gemfile":
            return "gemfile"
        case ".editorconfig":
            return "editorconfig"
        case ".prettierrc", ".prettierrc.json", ".prettierrc.js", ".prettierrc.yaml", ".prettierrc.yml", ".prettierignore":
            return "prettier"
        case ".eslintrc", ".eslintrc.json", ".eslintrc.js", ".eslintrc.yaml", ".eslintrc.yml", ".eslintignore":
            return "eslint"
        case "vite.config.js", "vite.config.ts", "vite.config.mjs":
            return "vite"
        case "next.config.js", "next.config.mjs", "next.config.ts":
            return "next"
        case "tailwind.config.js", "tailwind.config.ts", "tailwind.config.cjs":
            return "tailwind"
        case "webpack.config.js", "webpack.config.ts":
            return "webpack"
        case "jest.config.js", "jest.config.ts":
            return "jest"
        default:
            break
        }

        // 2. Extension Matches
        switch ext {
        case "swift":
            return "swift"
        case "ts", "mts", "cts":
            return "typescript"
        case "tsx":
            return "react_ts"
        case "js", "mjs", "cjs":
            return "javascript"
        case "jsx":
            return "react"
        case "py", "pyw", "pyi", "ipynb":
            return "python"
        case "rs", "rlib":
            return "rust"
        case "go":
            return "go"
        case "c", "h":
            return "c"
        case "cpp", "hpp", "cc", "cxx", "hh", "hxx":
            return "cpp"
        case "cs":
            return "csharp"
        case "java", "class", "jar":
            return "java"
        case "kt", "kts":
            return "kotlin"
        case "html", "htm", "xhtml":
            return "html"
        case "css":
            return "css"
        case "scss", "sass", "less", "styl":
            return "sass"
        case "json", "jsonc", "json5":
            return "json"
        case "yaml", "yml":
            return "yaml"
        case "toml":
            return "toml"
        case "md", "markdown", "mdx":
            return "markdown"
        case "sh", "bash", "zsh", "fish":
            return "console"
        case "sql":
            return "database"
        case "php", "phtml":
            return "php"
        case "rb", "rake", "gemspec":
            return "ruby"
        case "lua":
            return "lua"
        case "dart":
            return "dart"
        case "zig":
            return "zig"
        case "vue":
            return "vue"
        case "svelte":
            return "svelte"
        case "graphql", "gql":
            return "graphql"
        case "proto":
            return "proto"
        case "xml", "plist":
            return "xml"
        case "svg":
            return "svg"
        case "png", "jpg", "jpeg", "gif", "webp", "ico", "bmp", "tiff", "heic":
            return "image"
        case "mp4", "mov", "mkv", "webm", "avi", "flv":
            return "video"
        case "mp3", "wav", "ogg", "m4a", "flac", "aac":
            return "audio"
        case "zip", "tar", "gz", "tgz", "7z", "rar":
            return "zip"
        case "pdf":
            return "pdf"
        case "csv", "tsv", "xlsx", "xls":
            return "table"
        case "ttf", "otf", "woff", "woff2", "eot":
            return "font"
        default:
            return "document"
        }
    }
}

/// SwiftUI View rendering an authentic Material Icon Theme SVG.
public struct MaterialFileIcon: View {
    let url: URL
    let isDirectory: Bool
    let isExpanded: Bool
    let size: CGFloat

    public init(url: URL, isDirectory: Bool = false, isExpanded: Bool = false, size: CGFloat = 16) {
        self.url = url
        self.isDirectory = isDirectory
        self.isExpanded = isExpanded
        self.size = size
    }

    init(node: FileNode, isExpanded: Bool = false, size: CGFloat = 16) {
        self.url = node.url
        self.isDirectory = node.isDirectory
        self.isExpanded = isExpanded
        self.size = size
    }

    public var body: some View {
        let iconName = MaterialIconProvider.iconName(for: url, isDirectory: isDirectory, isExpanded: isExpanded)
        if let nsImage = MaterialIconCache.shared.image(named: iconName) {
            Image(nsImage: nsImage)
                .resizable()
                .renderingMode(.original)
                .aspectRatio(contentMode: .fit)
                .frame(width: size, height: size)
        } else {
            // Fallback system glyph if SVG asset cannot be loaded
            Image(systemName: isDirectory ? (isExpanded ? "folder.fill" : "folder") : "doc.text")
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: size, height: size)
                .foregroundStyle(isDirectory ? Color.orange : FlotillaColors.textSecondary)
        }
    }
}

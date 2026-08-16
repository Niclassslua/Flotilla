import SwiftUI
import DesignSystem

enum FileIconHelper {
    static func icon(for url: URL) -> (systemName: String, color: Color) {
        let ext = url.pathExtension.lowercased()
        let name = url.lastPathComponent.lowercased()

        switch (ext, name) {
        case (_, "package.json"), (_, "pnpm-lock.yaml"), (_, "yarn.lock"), (_, "bun.lockb"):
            return ("doc.text", .orange)
        case (_, "tsconfig.json"), (_, "jsconfig.json"):
            return ("gearshape", .blue)
        case (_, "dockerfile"), (_, "dockerfile.dev"), (_, "dockerfile.prod"):
            return ("shippingbox", .blue)
        case (_, "makefile"), (_, "makefile.am"), (_, "makefile.in"):
            return ("terminal", .purple)
        case (_, "license"), (_, "license.md"), (_, "license.txt"), (_, "copying"):
            return ("doc.text", .green)
        case (_, "readme"), (_, "readme.md"), (_, "readme.txt"), (_, "readme.rst"):
            return ("book", .blue)
        case (_, "changelog"), (_, "changelog.md"), (_, "changes"), (_, "changes.md"):
            return ("clock.arrow.circlepath", .purple)
        case (_, "contributing"), (_, "contributing.md"), (_, "code_of_conduct"), (_, "code_of_conduct.md"):
            return ("person.2", .pink)
        case (_, ".gitignore"), (_, ".gitattributes"), (_, ".gitmodules"):
            return ("arrow.triangle.branch", .orange)
        case (_, ".env"), (_, ".env.local"), (_, ".env.development"), (_, ".env.production"), (_, ".env.example"):
            return ("key", .green)
        case (_, "requirements.txt"), (_, "pyproject.toml"), (_, "setup.py"), (_, "setup.cfg"), (_, "pipfile"), (_, "pipfile.lock"), (_, "poetry.lock"):
            return ("doc.text", .blue)
        case (_, "cargo.toml"), (_, "cargo.lock"), (_, "rust-toolchain"), (_, "rust-toolchain.toml"):
            return ("doc.text", .orange)
        case (_, "go.mod"), (_, "go.sum"), (_, "go.work"):
            return ("doc.text", .cyan)
        case (_, "composer.json"), (_, "composer.lock"):
            return ("doc.text", .purple)
        case (_, "gemfile"), (_, "gemfile.lock"), (_, "gemspec"):
            return ("doc.text", .red)
        case (_, "package.swift"), (_, "package.resolved"):
            return ("doc.text", .orange)
        case (_, "xcodeproj"), (_, "xcworkspace"):
            return ("hammer", .blue)
        case (_, "podfile"), (_, "podfile.lock"), (_, "podspec"):
            return ("doc.text", .purple)
        case (_, "gradle"), (_, "gradle.kts"), (_, "build.gradle"), (_, "build.gradle.kts"), (_, "settings.gradle"), (_, "settings.gradle.kts"):
            return ("doc.text", .green)
        case (_, "maven"), (_, "pom.xml"):
            return ("doc.text", .red)
        case (_, "nginx.conf"), (_, "apache.conf"), (_, "httpd.conf"):
            return ("server.rack", .green)
        case (_, "vimrc"), (_, ".vimrc"), (_, "init.vim"), (_, ".ideavimrc"):
            return ("terminal", .green)
        case (_, "zshrc"), (_, ".zshrc"), (_, "bashrc"), (_, ".bashrc"), (_, "bash_profile"), (_, ".bash_profile"), (_, "profile"), (_, ".profile"):
            return ("terminal", .green)
        case (_, "gitconfig"), (_, ".gitconfig"):
            return ("gearshape", .orange)
        case (_, "ssh"), (_, "ssh_config"), (_, "sshd_config"), (_, "authorized_keys"), (_, "known_hosts"):
            return ("key", .red)
        default:
            switch ext {
            case "swift":
                return ("swift", .orange)
            case "swiftui":
                return ("swift", .blue)
            case "js", "jsx", "mjs", "cjs":
                return ("doc.text", .yellow)
            case "ts", "tsx", "mts", "cts":
                return ("doc.text", .blue)
            case "json", "jsonc", "json5":
                return ("curlybraces", .orange)
            case "md", "markdown", "mdx":
                return ("doc.richtext", .blue)
            case "txt", "log":
                return ("doc.text", .secondary)
            case "html", "htm", "xhtml":
                return ("doc.text", .red)
            case "css", "scss", "sass", "less", "styl":
                return ("doc.text", .pink)
            case "xml", "plist", "svg":
                return ("doc.text", .purple)
            case "yaml", "yml":
                return ("curlybraces", .red)
            case "toml":
                return ("curlybraces", .blue)
            case "ini", "cfg", "conf", "config":
                return ("gearshape", .secondary)
            case "py", "pyw", "pyi":
                return ("doc.text", .blue)
            case "rs", "rlib":
                return ("doc.text", .orange)
            case "go":
                return ("doc.text", .cyan)
            case "java", "class", "jar":
                return ("doc.text", .red)
            case "kt", "kts":
                return ("doc.text", .purple)
            case "scala", "sc":
                return ("doc.text", .red)
            case "c", "h":
                return ("doc.text", .blue)
            case "cpp", "cc", "cxx", "hpp", "hh", "hxx":
                return ("doc.text", .blue)
            case "cs":
                return ("doc.text", .purple)
            case "php", "phtml":
                return ("doc.text", .purple)
            case "rb", "rbw", "rake":
                return ("doc.text", .red)
            case "pl", "pm", "pod":
                return ("doc.text", .blue)
            case "lua":
                return ("doc.text", .blue)
            case "r", "rdata", "rds":
                return ("doc.text", .blue)
            case "sh", "bash", "zsh", "fish":
                return ("terminal", .green)
            case "ps1", "psm1", "psd1":
                return ("terminal", .blue)
            case "bat", "cmd":
                return ("terminal", .secondary)
            case "sql":
                return ("cylinder", .blue)
            case "graphql", "gql":
                return ("doc.text", .pink)
            case "proto":
                return ("doc.text", .purple)
            case "dockerfile":
                return ("shippingbox", .blue)
            case "tf", "tfvars", "hcl":
                return ("doc.text", .purple)
            case "vue":
                return ("doc.text", .green)
            case "svelte":
                return ("doc.text", .orange)
            case "astro":
                return ("doc.text", .purple)
            case "ex", "exs":
                return ("doc.text", .purple)
            case "erl", "hrl":
                return ("doc.text", .red)
            case "clj", "cljs", "cljc", "edn":
                return ("doc.text", .green)
            case "hs", "lhs":
                return ("doc.text", .purple)
            case "ml", "mli":
                return ("doc.text", .orange)
            case "fs", "fsx", "fsi":
                return ("doc.text", .blue)
            case "dart":
                return ("doc.text", .blue)
            case "zig":
                return ("doc.text", .orange)
            case "nim":
                return ("doc.text", .yellow)
            case "v", "vh":
                return ("doc.text", .blue)
            case "cr", "cr":
                return ("doc.text", .red)
            case "d":
                return ("doc.text", .blue)
            case "jl":
                return ("doc.text", .purple)
            case "awk":
                return ("doc.text", .secondary)
            case "sed":
                return ("doc.text", .secondary)
            case "asm", "s":
                return ("doc.text", .secondary)
            case "wasm", "wat":
                return ("doc.text", .purple)
            case "pdf":
                return ("doc.fill", .red)
            case "png", "jpg", "jpeg", "gif", "webp", "bmp", "tiff", "ico", "avif":
                return ("photo", .purple)
            case "svg":
                return ("photo", .pink)
            case "mp4", "mov", "avi", "mkv", "webm", "flv":
                return ("film", .purple)
            case "mp3", "wav", "flac", "ogg", "m4a", "aac":
                return ("music.note", .green)
            case "ttf", "otf", "woff", "woff2", "eot":
                return ("textformat", .purple)
            case "zip", "tar", "gz", "bz2", "xz", "7z", "rar":
                return ("archivebox", .orange)
            case "pem", "key", "crt", "cer", "der", "pfx", "p12":
                return ("key", .red)
            case "db", "sqlite", "sqlite3":
                return ("cylinder", .blue)
            case "csv", "tsv":
                return ("tablecells", .green)
            case "xls", "xlsx", "ods":
                return ("tablecells", .green)
            case "doc", "docx", "odt":
                return ("doc.fill", .blue)
            case "ppt", "pptx", "odp":
                return ("doc.fill", .orange)
            default:
                return ("doc.text", .secondary)
            }
        }
    }

    static func folderIcon(isExpanded: Bool) -> (systemName: String, color: Color) {
        if isExpanded {
            return ("folder.fill", .yellow)
        }
        return ("folder", .yellow)
    }
}

extension FileNode {
    var iconInfo: (systemName: String, color: Color) {
        if isDirectory {
            return FileIconHelper.folderIcon(isExpanded: children != nil && !(children?.isEmpty ?? true))
        }
        return FileIconHelper.icon(for: url)
    }
}
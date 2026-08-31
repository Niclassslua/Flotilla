import Foundation
import SwiftUI
import DesignSystem

/// What a `KnowledgeItem` came from.
///
/// Skills and Rules are two tabs over the same idea — files that tell an agent
/// how to behave in this project — so they render through one presentation
/// model and one set of designs. This enum carries the handful of places where
/// the two genuinely differ (empty-state copy, whether an item can be invoked).
enum KnowledgeKind: String, Sendable, Hashable {
    case skills
    case rules

    var title: String {
        switch self {
        case .skills: return "Skills"
        case .rules: return "Rules"
        }
    }

    var singular: String {
        switch self {
        case .skills: return "skill"
        case .rules: return "rule"
        }
    }

    var searchPrompt: String {
        switch self {
        case .skills: return "Search skills…"
        case .rules: return "Search rules…"
        }
    }

    var emptySymbol: String {
        switch self {
        case .skills: return "sparkles"
        case .rules: return "doc.badge.gearshape"
        }
    }
}

enum KnowledgeScope: String, Sendable, Hashable {
    case global
    case project

    var label: String { rawValue }
    var symbolName: String { self == .global ? "globe" : "folder" }
}

/// How an item draws its icon. Skills identify by the agent framework that owns
/// them; rules identify by the file itself, which `MaterialFileIcon` already
/// knows how to draw.
enum KnowledgeIcon: Sendable, Hashable {
    case framework(SkillFramework)
    case file(URL)

    /// Plugin-supplied skills override the framework glyph — the plugin, not
    /// the framework, is the interesting fact about them.
    case plugin
}

/// A colour role rather than a `Color`, so `KnowledgeItem` stays `Sendable` and
/// the palette resolves at render time (the app follows the system appearance).
enum KnowledgeMetricRole: Sendable, Hashable {
    case accent
    case info
    case success
    /// Draws attention to a fact that is probably a problem — an empty file.
    case warning
    case neutral

    var color: Color {
        switch self {
        case .accent: return FlotillaColors.accent
        case .info: return FlotillaColors.statusReady
        case .success: return FlotillaColors.statusWorking
        case .warning: return FlotillaColors.warning
        case .neutral: return FlotillaColors.textTertiary
        }
    }
}

struct KnowledgeMetric: Sendable, Hashable, Identifiable {
    let label: String
    let symbolName: String
    let role: KnowledgeMetricRole

    var id: String { "\(symbolName)-\(label)" }
}

/// The one model all four designs render. Both `SkillEntry` and `RuleFileEntry`
/// map into this, which is what lets a design be written once and serve both
/// tabs.
struct KnowledgeItem: Identifiable, Hashable, Sendable {
    let url: URL
    let kind: KnowledgeKind
    let title: String
    let subtitle: String
    let scope: KnowledgeScope
    let icon: KnowledgeIcon
    /// Framework badge text — `nil` for rules, which have no framework concept.
    let frameworkName: String?
    let framework: SkillFramework?
    /// Plugin name, when the item came from `~/.claude/plugins/<name>/skills`.
    let source: String?
    let version: String?
    /// Ready-to-paste invocation, e.g. `/review <path>`. Skills only.
    let invocation: String?
    let tags: [String]
    let metrics: [KnowledgeMetric]
    let author: String?
    let license: String?
    /// Document size weight for proportional calculations.
    let weight: Int
    /// On-disk size of the document itself, so an empty file is obvious at a
    /// glance without opening it.
    let byteSize: Int
    let lastModified: Date?
    let parentFolder: String

    var id: URL { url }

    /// The label shown on the scope chip. Plugin skills say which plugin they
    /// came from instead of just "global", which is the more useful fact.
    var scopeLabel: String { source ?? scope.label }
}

// MARK: - Mapping

extension KnowledgeItem {
    init(skill: SkillEntry) {
        let stats = skill.bundleStats
        var metrics: [KnowledgeMetric] = []
        if stats.scriptsCount > 0 {
            metrics.append(KnowledgeMetric(
                label: "\(stats.scriptsCount) script\(stats.scriptsCount == 1 ? "" : "s")",
                symbolName: "bolt.fill",
                role: .accent
            ))
        }
        if stats.referencesCount > 0 {
            metrics.append(KnowledgeMetric(
                label: "\(stats.referencesCount) doc\(stats.referencesCount == 1 ? "" : "s")",
                symbolName: "doc.text.fill",
                role: .info
            ))
        }
        if stats.dataCount > 0 {
            metrics.append(KnowledgeMetric(
                label: "\(stats.dataCount) data",
                symbolName: "tablecells.fill",
                role: .success
            ))
        }
        let byteSize = KnowledgeItem.fileSize(at: skill.url)
        metrics.append(KnowledgeMetric(
            label: formatByteSize(byteSize),
            symbolName: "doc",
            role: byteSize == 0 ? .warning : .neutral
        ))
        metrics.append(KnowledgeMetric(
            label: "\(stats.lineCount) lines",
            symbolName: "text.alignleft",
            role: .neutral
        ))

        self.init(
            url: skill.url,
            kind: .skills,
            title: skill.name,
            subtitle: skill.description.isEmpty ? "No description provided." : skill.description,
            scope: skill.scope == .global ? .global : .project,
            icon: skill.source != nil ? .plugin : .framework(skill.framework),
            frameworkName: skill.framework.displayName,
            framework: skill.framework,
            source: skill.source,
            version: skill.version,
            invocation: skill.argumentHint.map { "/\(skill.name) \($0)" },
            tags: skill.tags,
            metrics: metrics,
            author: skill.author,
            license: skill.license,
            weight: stats.lineCount,
            byteSize: byteSize,
            lastModified: stats.lastModified,
            parentFolder: skill.url.deletingLastPathComponent().lastPathComponent
        )
    }

    init(rule: RuleFileEntry) {
        let attributes = try? FileManager.default.attributesOfItem(atPath: rule.url.path)
        let byteSize = (attributes?[.size] as? NSNumber)?.intValue ?? 0

        self.init(
            url: rule.url,
            kind: .rules,
            title: rule.relativePath,
            subtitle: KnowledgeItem.ruleSubtitle(for: rule.relativePath),
            scope: rule.scope == .global ? .global : .project,
            icon: .file(rule.url),
            frameworkName: nil,
            framework: nil,
            source: nil,
            version: nil,
            invocation: nil,
            tags: [],
            metrics: [
                KnowledgeMetric(
                    label: formatByteSize(byteSize),
                    symbolName: "doc",
                    role: byteSize == 0 ? .warning : .neutral
                )
            ],
            author: nil,
            license: nil,
            // Rules carry no line count, so approximate one from the byte size
            // to give the mosaic something to vary tile heights on.
            weight: byteSize / 40,
            byteSize: byteSize,
            lastModified: attributes?[.modificationDate] as? Date,
            parentFolder: rule.url.deletingLastPathComponent().lastPathComponent
        )
    }

    /// Rules carry no frontmatter, so the only description available is one
    /// inferred from the filename. Kept verbatim from the two copies this
    /// replaced so the copy users already know doesn't change.
    static func ruleSubtitle(for name: String) -> String {
        let name = name.lowercased()
        if name.contains("claude") {
            return "Claude Code instructions & workflow policies"
        } else if name.contains("gemini") {
            return "Gemini CLI system context & project guidance"
        } else if name.contains("agent") {
            return "Autonomous coding agent guide & architecture reference"
        } else if name.contains("cursor") {
            return "Cursor IDE workspace rules & code conventions"
        } else if name.contains("copilot") {
            return "GitHub Copilot prompt instructions"
        } else {
            return "AI assistant instruction file"
        }
    }
}

// MARK: - Formatting

extension KnowledgeItem {
    static func fileSize(at url: URL) -> Int {
        let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
        return (attributes?[.size] as? NSNumber)?.intValue ?? 0
    }
}

/// Human-readable file size. An empty document says so in words rather than
/// "0 bytes", because "is this file empty?" is the question the number is
/// there to answer.
func formatByteSize(_ bytes: Int) -> String {
    guard bytes > 0 else { return "empty" }
    let formatter = ByteCountFormatter()
    formatter.countStyle = .file
    formatter.allowsNonnumericFormatting = false
    return formatter.string(fromByteCount: Int64(bytes))
}

/// Compact relative date for prose contexts: "just now", "12 min ago",
/// "3d ago", then an absolute "MMM d" once a week has passed.
///
/// Minutes spell out as "min": "2m ago" reads as either two minutes or two
/// months, and the same column carried both registers.
///
/// Not for table columns — mixing relative and absolute values in one column
/// makes the rows incomparable by eye. Use `formatLedgerDate` there.
func formatRelativeDate(_ date: Date) -> String {
    let seconds = max(0, Date().timeIntervalSince(date))
    if seconds < 60 {
        return "just now"
    } else if seconds < 3600 {
        return "\(Int(seconds / 60)) min ago"
    } else if seconds < 86400 {
        return "\(Int(seconds / 3600))h ago"
    } else if seconds < 86400 * 7 {
        return "\(Int(seconds / 86400))d ago"
    } else {
        let formatter = DateFormatter()
        formatter.dateFormat = "MMM d"
        return formatter.string(from: date)
    }
}

/// One register for a whole date column, so every row can be compared against
/// every other at a glance. Today collapses to a clock time; anything older
/// than the current year carries its year rather than silently colliding with
/// a date twelve months away.
func formatLedgerDate(_ date: Date) -> String {
    let calendar = Calendar.current
    let formatter = DateFormatter()
    if calendar.isDateInToday(date) {
        formatter.dateFormat = "HH:mm"
    } else if calendar.component(.year, from: date) == calendar.component(.year, from: Date()) {
        formatter.dateFormat = "MMM d"
    } else {
        formatter.dateFormat = "MMM d yy"
    }
    return formatter.string(from: date)
}

import Foundation
import SessionKit

public enum SkillScope: String, Sendable, Hashable, Codable {
    case global
    case project
}

public enum SkillFramework: String, Sendable, Hashable, Codable, CaseIterable {
    case claude
    case agents
    case codex
    case cursor
    case gemini
    case custom

    public var displayName: String {
        switch self {
        case .claude: return "Claude"
        case .agents: return "Agents"
        case .codex: return "Codex"
        case .cursor: return "Cursor"
        case .gemini: return "Gemini"
        case .custom: return "Custom"
        }
    }

    public var agentKind: AgentKind? {
        switch self {
        case .claude: return .claudeCode
        case .codex: return .codexCLI
        case .gemini: return .antigravity
        case .agents, .cursor, .custom: return nil
        }
    }

    public var logoAssetName: String? {
        switch self {
        case .claude: return "ProviderLogoClaude"
        case .codex: return "ProviderLogoCodex"
        case .cursor: return "ProviderLogoCursor"
        case .gemini: return "ProviderLogoAntigravity"
        case .agents, .custom: return nil
        }
    }

    public var iconSystemName: String {
        switch self {
        case .claude: return "sparkles"
        case .agents: return "person.2.badge.gearshape"
        case .codex: return "chevron.left.forwardslash.chevron.right"
        case .cursor: return "cursorarrow.rays"
        case .gemini: return "wand.and.stars"
        case .custom: return "puzzlepiece.extension.fill"
        }
    }
}

public struct SkillBundleStats: Sendable, Hashable, Codable {
    public var scriptsCount: Int
    public var referencesCount: Int
    public var dataCount: Int
    public var totalFilesCount: Int
    public var lineCount: Int
    public var wordCount: Int
    public var estimatedReadMinutes: Int
    public var lastModified: Date?

    public init(
        scriptsCount: Int = 0,
        referencesCount: Int = 0,
        dataCount: Int = 0,
        totalFilesCount: Int = 0,
        lineCount: Int = 0,
        wordCount: Int = 0,
        estimatedReadMinutes: Int = 1,
        lastModified: Date? = nil
    ) {
        self.scriptsCount = scriptsCount
        self.referencesCount = referencesCount
        self.dataCount = dataCount
        self.totalFilesCount = totalFilesCount
        self.lineCount = lineCount
        self.wordCount = wordCount
        self.estimatedReadMinutes = estimatedReadMinutes
        self.lastModified = lastModified
    }
}

public struct SkillEntry: Identifiable, Hashable, Sendable {
    public let url: URL              // the SKILL.md
    public let name: String          // frontmatter `name`, else directory name
    public let description: String   // frontmatter `description`
    public let scope: SkillScope     // .global | .project
    public let framework: SkillFramework
    public let source: String?       // plugin name when under ~/.claude/plugins
    public let version: String?
    public let argumentHint: String?
    public let userInvocable: Bool?
    public let author: String?
    public let license: String?
    public let tags: [String]
    public let bundleStats: SkillBundleStats
    public var id: URL { url }

    public init(
        url: URL,
        name: String,
        description: String,
        scope: SkillScope,
        framework: SkillFramework = .custom,
        source: String? = nil,
        version: String? = nil,
        argumentHint: String? = nil,
        userInvocable: Bool? = nil,
        author: String? = nil,
        license: String? = nil,
        tags: [String] = [],
        bundleStats: SkillBundleStats = SkillBundleStats()
    ) {
        self.url = url
        self.name = name
        self.description = description
        self.scope = scope
        self.framework = framework
        self.source = source
        self.version = version
        self.argumentHint = argumentHint
        self.userInvocable = userInvocable
        self.author = author
        self.license = license
        self.tags = tags
        self.bundleStats = bundleStats
    }
}


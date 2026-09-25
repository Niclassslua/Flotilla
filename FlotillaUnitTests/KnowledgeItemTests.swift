import XCTest
@testable import Flotilla

/// Covers the mapping that lets Skills and Rules share one set of designs: two
/// unrelated source models must land on the same `KnowledgeItem` fields, and
/// the search predicate that replaced the tabs' two separate ones must still
/// match everything either of them used to.
final class KnowledgeItemTests: XCTestCase {

    // MARK: - Fixtures

    private func makeSkill(
        name: String = "code-review",
        description: String = "Reviews a diff.",
        scope: SkillScope = .project,
        framework: SkillFramework = .claude,
        source: String? = nil,
        version: String? = "1.2.0",
        argumentHint: String? = nil,
        tags: [String] = [],
        stats: SkillBundleStats = SkillBundleStats()
    ) -> SkillEntry {
        SkillEntry(
            url: URL(fileURLWithPath: "/tmp/proj/.claude/skills/\(name)/SKILL.md"),
            name: name,
            description: description,
            scope: scope,
            framework: framework,
            source: source,
            version: version,
            argumentHint: argumentHint,
            tags: tags,
            bundleStats: stats
        )
    }

    private func makeRule(
        relativePath: String = "CLAUDE.md",
        scope: RuleScope = .project
    ) -> RuleFileEntry {
        RuleFileEntry(
            url: URL(fileURLWithPath: "/tmp/proj/\(relativePath)"),
            relativePath: relativePath,
            scope: scope
        )
    }

    // MARK: - Skill mapping

    func testSkillMappingFieldsInvocationIconAndMetrics() {
        let item = KnowledgeItem(skill: makeSkill(tags: ["review", "git"]))
        XCTAssertEqual(item.kind, .skills)
        XCTAssertEqual(item.title, "code-review")
        XCTAssertEqual(item.subtitle, "Reviews a diff.")
        XCTAssertEqual(item.scope, .project)
        XCTAssertEqual(item.frameworkName, "Claude")
        XCTAssertEqual(item.version, "1.2.0")
        XCTAssertEqual(item.tags, ["review", "git"])
        XCTAssertEqual(item.parentFolder, "code-review")

        XCTAssertEqual(
            KnowledgeItem(skill: makeSkill(description: "")).subtitle,
            "No description provided."
        )
        XCTAssertEqual(
            KnowledgeItem(skill: makeSkill(name: "review", argumentHint: "<path>")).invocation,
            "/review <path>"
        )
        XCTAssertNil(KnowledgeItem(skill: makeSkill(argumentHint: nil)).invocation)

        let plugin = KnowledgeItem(skill: makeSkill(scope: .global, source: "acme-pack"))
        XCTAssertEqual(plugin.icon, .plugin)
        XCTAssertEqual(plugin.scopeLabel, "acme-pack")

        let nonPlugin = KnowledgeItem(skill: makeSkill(scope: .global, framework: .codex))
        XCTAssertEqual(nonPlugin.icon, .framework(.codex))
        XCTAssertEqual(nonPlugin.scopeLabel, "global")

        let stats = SkillBundleStats(
            scriptsCount: 2,
            referencesCount: 0,
            dataCount: 3,
            lineCount: 240,
            estimatedReadMinutes: 4
        )
        let labels = KnowledgeItem(skill: makeSkill(stats: stats)).metrics.map(\.label)
        XCTAssertTrue(labels.contains("2 scripts"))
        XCTAssertTrue(labels.contains("3 data"))
        XCTAssertFalse(labels.contains { $0.hasSuffix("docs") }, "a zero count should not get a pill")
        XCTAssertTrue(labels.contains("240 lines"))

        let emptyMetric = KnowledgeItem(skill: makeSkill()).metrics.first { $0.symbolName == "doc" }
        XCTAssertEqual(emptyMetric?.label, "empty")
        XCTAssertEqual(emptyMetric?.role, .warning)
    }

    // MARK: - Rule mapping

    func testRuleMapsPathAsTitleAndCarriesNoSkillOnlyFields() {
        let item = KnowledgeItem(rule: makeRule(relativePath: "docs/AGENTS.md"))

        XCTAssertEqual(item.kind, .rules)
        XCTAssertEqual(item.title, "docs/AGENTS.md")
        XCTAssertNil(item.frameworkName)
        XCTAssertNil(item.invocation)
        XCTAssertNil(item.version)
        XCTAssertTrue(item.tags.isEmpty)
        XCTAssertEqual(item.metrics.map(\.symbolName), ["doc"], "a rule's only metric is its size")
    }

    // MARK: - Search

    func testSearchMatchesFieldsCaseInsensitivelyIncludingRules() {
        let item = KnowledgeItem(skill: makeSkill(
            name: "code-review",
            description: "Reviews a diff.",
            framework: .codex,
            source: "acme-pack",
            version: "1.2.0",
            argumentHint: "<path>",
            tags: ["git"]
        ))

        XCTAssertTrue(item.matches("code"), "title")
        XCTAssertTrue(item.matches("diff"), "description")
        XCTAssertTrue(item.matches("acme"), "plugin source")
        XCTAssertTrue(item.matches("Codex"), "framework name")
        XCTAssertTrue(item.matches("1.2"), "version")
        XCTAssertTrue(item.matches("<path>"), "invocation")
        XCTAssertTrue(item.matches("git"), "tag")
        XCTAssertFalse(item.matches("nonsense"))

        let cased = KnowledgeItem(skill: makeSkill(name: "Code-Review"))
        XCTAssertTrue(cased.matches("code-review"))
        XCTAssertTrue(cased.matches("CODE-REVIEW"))

        let rule = KnowledgeItem(rule: makeRule(relativePath: "docs/AGENTS.md"))
        XCTAssertTrue(rule.matches("agents"))
        XCTAssertTrue(rule.matches("docs"))
    }

    // MARK: - Relative dates

    func testLedgerAndRelativeDateFormatting() {
        let now = Date()
        for offset in [0, -120, -7200, -86400 * 3, -86400 * 30, -86400 * 400] {
            let rendered = formatLedgerDate(now.addingTimeInterval(TimeInterval(offset)))
            XCTAssertFalse(rendered.hasSuffix("ago"), "\(rendered) is relative")
            XCTAssertFalse(rendered.contains("just now"), "\(rendered) is relative")
        }
        XCTAssertFalse(formatLedgerDate(now.addingTimeInterval(-86400 * 3)).contains(":"))
        XCTAssertTrue(formatLedgerDate(now).contains(":"))

        let old = Date().addingTimeInterval(-86400 * 30)
        XCTAssertFalse(formatRelativeDate(old).hasSuffix("ago"))
        XCTAssertEqual(formatRelativeDate(Date().addingTimeInterval(600)), "just now")
    }
}

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

    func testSkillMapsCoreFields() {
        let item = KnowledgeItem(skill: makeSkill(tags: ["review", "git"]))

        XCTAssertEqual(item.kind, .skills)
        XCTAssertEqual(item.title, "code-review")
        XCTAssertEqual(item.subtitle, "Reviews a diff.")
        XCTAssertEqual(item.scope, .project)
        XCTAssertEqual(item.frameworkName, "Claude")
        XCTAssertEqual(item.version, "1.2.0")
        XCTAssertEqual(item.tags, ["review", "git"])
        XCTAssertEqual(item.parentFolder, "code-review")
    }

    func testSkillWithoutDescriptionGetsPlaceholderRatherThanBlank() {
        let item = KnowledgeItem(skill: makeSkill(description: ""))
        XCTAssertEqual(item.subtitle, "No description provided.")
    }

    func testSkillInvocationCombinesNameAndArgumentHint() {
        let item = KnowledgeItem(skill: makeSkill(name: "review", argumentHint: "<path>"))
        XCTAssertEqual(item.invocation, "/review <path>")
    }

    func testSkillWithoutArgumentHintHasNoInvocation() {
        XCTAssertNil(KnowledgeItem(skill: makeSkill(argumentHint: nil)).invocation)
    }

    func testPluginSkillUsesPluginIconAndReportsPluginAsScopeLabel() {
        let item = KnowledgeItem(skill: makeSkill(scope: .global, source: "acme-pack"))

        XCTAssertEqual(item.icon, .plugin)
        // The plugin name is the useful fact, not that it happens to be global.
        XCTAssertEqual(item.scopeLabel, "acme-pack")
    }

    func testNonPluginSkillFallsBackToFrameworkIconAndScopeLabel() {
        let item = KnowledgeItem(skill: makeSkill(scope: .global, framework: .codex))

        XCTAssertEqual(item.icon, .framework(.codex))
        XCTAssertEqual(item.scopeLabel, "global")
    }

    func testBundleStatsBecomeMetricsAndOnlyNonZeroCountsAppear() {
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
    }

    func testReadTimeIsNotShown() {
        let stats = SkillBundleStats(lineCount: 240, estimatedReadMinutes: 4)
        let labels = KnowledgeItem(skill: makeSkill(stats: stats)).metrics.map(\.label)

        XCTAssertFalse(labels.contains { $0.contains("min read") }, "read time was dropped in favour of file size")
    }

    func testEverySkillGetsASizeMetric() {
        let metrics = KnowledgeItem(skill: makeSkill()).metrics
        XCTAssertTrue(metrics.contains { $0.symbolName == "doc" })
    }

    func testMissingFileReportsZeroSizeAndFlagsItAsAWarning() {
        // The fixture path does not exist, which is the same shape as a file
        // that is genuinely empty.
        let metric = KnowledgeItem(skill: makeSkill()).metrics.first { $0.symbolName == "doc" }

        XCTAssertEqual(metric?.label, "empty")
        XCTAssertEqual(metric?.role, .warning, "an empty document should stand out, not read as neutral detail")
    }

    func testSingleScriptIsNotPluralised() {
        let stats = SkillBundleStats(scriptsCount: 1, referencesCount: 1)
        let labels = KnowledgeItem(skill: makeSkill(stats: stats)).metrics.map(\.label)

        XCTAssertTrue(labels.contains("1 script"))
        XCTAssertTrue(labels.contains("1 doc"))
    }

    func testWeightComesFromLineCountSoMosaicTilesCanBeSized() {
        let item = KnowledgeItem(skill: makeSkill(stats: SkillBundleStats(lineCount: 512)))
        XCTAssertEqual(item.weight, 512)
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

    func testGlobalRuleKeepsGlobalScope() {
        XCTAssertEqual(KnowledgeItem(rule: makeRule(scope: .global)).scope, .global)
    }

    func testRuleSubtitleIsInferredFromFilename() {
        XCTAssertEqual(
            KnowledgeItem.ruleSubtitle(for: "CLAUDE.md"),
            "Claude Code instructions & workflow policies"
        )
        XCTAssertEqual(
            KnowledgeItem.ruleSubtitle(for: "AGENTS.md"),
            "Autonomous coding agent guide & architecture reference"
        )
        XCTAssertEqual(
            KnowledgeItem.ruleSubtitle(for: ".cursorrules"),
            "Cursor IDE workspace rules & code conventions"
        )
        XCTAssertEqual(
            KnowledgeItem.ruleSubtitle(for: "copilot-instructions.md"),
            "GitHub Copilot prompt instructions"
        )
        XCTAssertEqual(
            KnowledgeItem.ruleSubtitle(for: "something-else.md"),
            "AI assistant instruction file"
        )
    }

    func testRuleSubtitleMatchIsCaseInsensitive() {
        XCTAssertEqual(
            KnowledgeItem.ruleSubtitle(for: "claude.md"),
            "Claude Code instructions & workflow policies"
        )
    }

    // MARK: - Search

    func testSearchMatchesEveryFieldTheTwoTabsUsedToSearchSeparately() {
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
    }

    func testSearchIsCaseInsensitive() {
        let item = KnowledgeItem(skill: makeSkill(name: "Code-Review"))
        XCTAssertTrue(item.matches("code-review"))
        XCTAssertTrue(item.matches("CODE-REVIEW"))
    }

    func testRuleSearchMatchesPath() {
        let item = KnowledgeItem(rule: makeRule(relativePath: "docs/AGENTS.md"))
        XCTAssertTrue(item.matches("agents"))
        XCTAssertTrue(item.matches("docs"))
    }

    // MARK: - Byte sizes

    func testEmptyFileSaysSoInWords() {
        // "0 bytes" makes the reader do the comparison; "empty" answers it.
        XCTAssertEqual(formatByteSize(0), "empty")
    }

    func testByteSizesAreHumanReadable() {
        XCTAssertEqual(formatByteSize(512), "512 bytes")
        XCTAssertTrue(formatByteSize(4096).contains("KB"))
        XCTAssertTrue(formatByteSize(5_000_000).contains("MB"))
    }

    // MARK: - Relative dates

    func testRelativeDateBuckets() {
        let now = Date()
        XCTAssertEqual(formatRelativeDate(now), "just now")
        XCTAssertEqual(formatRelativeDate(now.addingTimeInterval(-120)), "2m ago")
        XCTAssertEqual(formatRelativeDate(now.addingTimeInterval(-7200)), "2h ago")
        XCTAssertEqual(formatRelativeDate(now.addingTimeInterval(-86400 * 3)), "3d ago")
    }

    func testRelativeDateFallsBackToAbsoluteAfterAWeek() {
        let old = Date().addingTimeInterval(-86400 * 30)
        // Past a week the bucket labels stop being useful, so we show a date.
        XCTAssertFalse(formatRelativeDate(old).hasSuffix("ago"))
    }

    /// A clock skew that puts a file's mtime in the future shouldn't render as
    /// a negative age.
    func testFutureDateClampsToJustNow() {
        XCTAssertEqual(formatRelativeDate(Date().addingTimeInterval(600)), "just now")
    }
}

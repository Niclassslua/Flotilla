import XCTest
@testable import Flotilla

final class SkillFrontmatterTests: XCTestCase {

    func testParsesStandardQuotedFoldedCRLFAndExtendedFields() {
        let standard = """
        ---
        name: code-review
        description: Performs code reviews on pull requests.
        ---
        # Skill Body
        Instructions here.
        """
        let parsedStandard = SkillFrontmatter.parse(standard)
        XCTAssertEqual(parsedStandard.name, "code-review")
        XCTAssertEqual(parsedStandard.description, "Performs code reviews on pull requests.")

        let quoted = """
        ---
        name: "my-skill"
        description: 'A helpful skill for formatting.'
        ---
        Body
        """
        let parsedQuoted = SkillFrontmatter.parse(quoted)
        XCTAssertEqual(parsedQuoted.name, "my-skill")
        XCTAssertEqual(parsedQuoted.description, "A helpful skill for formatting.")

        let folded = """
        ---
        name: doc-generator
        description: >
          Generates comprehensive documentation
          for Swift and TypeScript codebases.
        ---
        Body
        """
        let parsedFolded = SkillFrontmatter.parse(folded)
        XCTAssertEqual(parsedFolded.name, "doc-generator")
        XCTAssertEqual(
            parsedFolded.description,
            "Generates comprehensive documentation for Swift and TypeScript codebases."
        )

        let crlf = "---\r\nname: crlf-skill\r\ndescription: Works with CRLF.\r\n---\r\nBody"
        let parsedCRLF = SkillFrontmatter.parse(crlf)
        XCTAssertEqual(parsedCRLF.name, "crlf-skill")
        XCTAssertEqual(parsedCRLF.description, "Works with CRLF.")

        let extended = """
        ---
        name: impeccable
        description: Create distinctive, production-grade frontend interfaces.
        version: 2.1.1
        user-invocable: true
        argument-hint: "[craft|teach|extract]"
        author: Anthropic
        license: Apache-2.0
        tags: [swift, ui, design]
        ---
        Body content
        """
        let parsedExtended = SkillFrontmatter.parse(extended)
        XCTAssertEqual(parsedExtended.name, "impeccable")
        XCTAssertEqual(parsedExtended.version, "2.1.1")
        XCTAssertEqual(parsedExtended.userInvocable, true)
        XCTAssertEqual(parsedExtended.argumentHint, "[craft|teach|extract]")
        XCTAssertEqual(parsedExtended.author, "Anthropic")
        XCTAssertEqual(parsedExtended.license, "Apache-2.0")
        XCTAssertEqual(parsedExtended.tags, ["swift", "ui", "design"])
    }

    func testMissingOrUnclosedFrontmatterYieldsNilFields() {
        let none = """
        # Just Markdown
        No frontmatter in this file.
        """
        let parsedNone = SkillFrontmatter.parse(none)
        XCTAssertNil(parsedNone.name)
        XCTAssertNil(parsedNone.description)

        let unclosed = """
        ---
        name: broken
        description: never closes
        """
        let parsedUnclosed = SkillFrontmatter.parse(unclosed)
        XCTAssertNil(parsedUnclosed.name)
        XCTAssertNil(parsedUnclosed.description)
    }

    func testParsesMarkdownFallbackWhenNoFrontmatter() {
        let text = """
        # ui-ux-pro-max

        Comprehensive design guide for web and mobile applications. Contains styles and palettes.

        ## Prerequisites
        Check Python
        """

        let parsed = SkillFrontmatter.parseWithFallback(text, fallbackDirName: "ui-ux-pro-max-dir")
        XCTAssertEqual(parsed.name, "ui-ux-pro-max")
        XCTAssertTrue(parsed.description?.contains("Comprehensive design guide") == true)
    }
}

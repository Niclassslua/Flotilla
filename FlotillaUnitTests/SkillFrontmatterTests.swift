import XCTest
@testable import Flotilla

final class SkillFrontmatterTests: XCTestCase {

    func testParsesStandardNameAndDescription() {
        let text = """
        ---
        name: code-review
        description: Performs code reviews on pull requests.
        ---
        # Skill Body
        Instructions here.
        """

        let parsed = SkillFrontmatter.parse(text)
        XCTAssertEqual(parsed.name, "code-review")
        XCTAssertEqual(parsed.description, "Performs code reviews on pull requests.")
    }

    func testParsesQuotedValues() {
        let text = """
        ---
        name: "my-skill"
        description: 'A helpful skill for formatting.'
        ---
        Body
        """

        let parsed = SkillFrontmatter.parse(text)
        XCTAssertEqual(parsed.name, "my-skill")
        XCTAssertEqual(parsed.description, "A helpful skill for formatting.")
    }

    func testParsesMultiLineFoldedDescription() {
        let text = """
        ---
        name: doc-generator
        description: >
          Generates comprehensive documentation
          for Swift and TypeScript codebases.
        ---
        Body
        """

        let parsed = SkillFrontmatter.parse(text)
        XCTAssertEqual(parsed.name, "doc-generator")
        XCTAssertEqual(parsed.description, "Generates comprehensive documentation for Swift and TypeScript codebases.")
    }

    func testHandlesCRLFLineEndings() {
        let text = "---\r\nname: crlf-skill\r\ndescription: Works with CRLF.\r\n---\r\nBody"

        let parsed = SkillFrontmatter.parse(text)
        XCTAssertEqual(parsed.name, "crlf-skill")
        XCTAssertEqual(parsed.description, "Works with CRLF.")
    }

    func testReturnsNilWhenNoFrontmatterPresent() {
        let text = """
        # Just Markdown
        No frontmatter in this file.
        """

        let parsed = SkillFrontmatter.parse(text)
        XCTAssertNil(parsed.name)
        XCTAssertNil(parsed.description)
    }

    func testReturnsNilWhenFrontmatterIsUnclosed() {
        let text = """
        ---
        name: broken
        description: never closes
        """

        let parsed = SkillFrontmatter.parse(text)
        XCTAssertNil(parsed.name)
        XCTAssertNil(parsed.description)
    }

    func testParsesExtendedFieldsAndTags() {
        let text = """
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

        let parsed = SkillFrontmatter.parse(text)
        XCTAssertEqual(parsed.name, "impeccable")
        XCTAssertEqual(parsed.description, "Create distinctive, production-grade frontend interfaces.")
        XCTAssertEqual(parsed.version, "2.1.1")
        XCTAssertEqual(parsed.userInvocable, true)
        XCTAssertEqual(parsed.argumentHint, "[craft|teach|extract]")
        XCTAssertEqual(parsed.author, "Anthropic")
        XCTAssertEqual(parsed.license, "Apache-2.0")
        XCTAssertEqual(parsed.tags, ["swift", "ui", "design"])
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

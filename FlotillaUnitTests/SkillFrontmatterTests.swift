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
}

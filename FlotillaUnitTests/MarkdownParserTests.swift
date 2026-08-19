import XCTest
import MarkdownParser
@testable import Flotilla

final class MarkdownParserTests: XCTestCase {

    func testHeadingsParsing() {
        let markdown = """
        # Heading 1
        ## Heading 2
        ### Heading 3
        """

        let blocks = MarkdownDocument.blocks(from: markdown)
        XCTAssertEqual(blocks.count, 3)

        guard case .heading(let level1, let text1) = blocks[0],
              case .heading(let level2, let text2) = blocks[1],
              case .heading(let level3, let text3) = blocks[2] else {
            return XCTFail("Expected 3 heading blocks")
        }

        XCTAssertEqual(level1, 1)
        XCTAssertEqual(String(text1.characters), "Heading 1")
        XCTAssertEqual(level2, 2)
        XCTAssertEqual(String(text2.characters), "Heading 2")
        XCTAssertEqual(level3, 3)
        XCTAssertEqual(String(text3.characters), "Heading 3")
    }

    func testCodeBlocksWithLanguage() {
        let markdown = """
        ```swift
        func hello() -> String {
            return "world"
        }
        ```
        """

        let blocks = MarkdownDocument.blocks(from: markdown)
        XCTAssertEqual(blocks.count, 1)

        guard case .codeBlock(let language, let code) = blocks[0] else {
            return XCTFail("Expected codeBlock")
        }

        XCTAssertEqual(language, "swift")
        XCTAssertTrue(code.contains("func hello()"))
        XCTAssertTrue(code.contains("return \"world\""))
    }

    func testUnorderedListPreservesBodyText() {
        let markdown = """
        - First item with **bold** text
        * Second item with `inline code`
        + Third item
        """

        let blocks = MarkdownDocument.blocks(from: markdown)
        XCTAssertEqual(blocks.count, 3)

        guard case .listItem(let ordered1, _, let text1) = blocks[0],
              case .listItem(let ordered2, _, let text2) = blocks[1],
              case .listItem(let ordered3, _, let text3) = blocks[2] else {
            return XCTFail("Expected 3 listItem blocks")
        }

        XCTAssertFalse(ordered1)
        XCTAssertEqual(String(text1.characters), "First item with bold text")
        XCTAssertFalse(ordered2)
        XCTAssertEqual(String(text2.characters), "Second item with inline code")
        XCTAssertFalse(ordered3)
        XCTAssertEqual(String(text3.characters), "Third item")
    }

    func testOrderedListPreservesBodyText() {
        let markdown = """
        1. Step one
        2. Step two
        3. Step three
        """

        let blocks = MarkdownDocument.blocks(from: markdown)
        XCTAssertEqual(blocks.count, 3)

        guard case .listItem(let ordered1, _, let text1) = blocks[0] else {
            return XCTFail("Expected listItem block")
        }

        XCTAssertTrue(ordered1)
        XCTAssertEqual(String(text1.characters), "Step one")
    }

    func testBlockQuoteParsing() {
        let markdown = """
        > This is a quote.
        > Second line of quote.
        """

        let blocks = MarkdownDocument.blocks(from: markdown)
        XCTAssertEqual(blocks.count, 1)

        guard case .blockQuote(let inner) = blocks[0] else {
            return XCTFail("Expected blockQuote")
        }

        XCTAssertFalse(inner.isEmpty)
    }

    func testThematicBreak() {
        let markdown = """
        Paragraph above

        ---

        Paragraph below
        """

        let blocks = MarkdownDocument.blocks(from: markdown)
        XCTAssertEqual(blocks.count, 3)

        guard case .paragraph = blocks[0],
              case .thematicBreak = blocks[1],
              case .paragraph = blocks[2] else {
            return XCTFail("Expected paragraph, thematicBreak, paragraph")
        }
    }
}

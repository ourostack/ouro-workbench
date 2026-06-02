import XCTest
@testable import OuroWorkbenchCore

final class MarkdownMessageTests: XCTestCase {
    func testClassifiesHeadingsBulletsParagraphsAndBlanks() {
        let text = """
        # Title
        ### Sub
        Plain paragraph
        - bullet one
        * bullet two

        last
        """
        let blocks = BossMessageMarkdown.blocks(from: text)
        XCTAssertEqual(blocks[0], .heading(level: 1, text: "Title"))
        XCTAssertEqual(blocks[1], .heading(level: 3, text: "Sub"))
        XCTAssertEqual(blocks[2], .paragraph(text: "Plain paragraph"))
        XCTAssertEqual(blocks[3], .bullet(indent: 0, text: "bullet one"))
        XCTAssertEqual(blocks[4], .bullet(indent: 0, text: "bullet two"))
        XCTAssertEqual(blocks[5], .blank)
        XCTAssertEqual(blocks[6], .paragraph(text: "last"))
    }

    func testBoldHeaderLineStaysParagraphNotHeading() {
        // The boss writes `**Watch-mode check-in:**` (no '#') — keep it a
        // paragraph so the inline bold renders, not a literal heading.
        let blocks = BossMessageMarkdown.blocks(from: "**Watch-mode check-in:**")
        XCTAssertEqual(blocks, [.paragraph(text: "**Watch-mode check-in:**")])
    }

    func testBulletKeepsInlineMarksForTheView() {
        let blocks = BossMessageMarkdown.blocks(from: "- **Running:** 1 active terminal")
        XCTAssertEqual(blocks, [.bullet(indent: 0, text: "**Running:** 1 active terminal")])
    }

    func testNestedBulletIndentByLeadingSpaces() {
        let blocks = BossMessageMarkdown.blocks(from: "    - nested")
        XCTAssertEqual(blocks, [.bullet(indent: 2, text: "nested")])
    }

    func testHashWithoutSpaceIsNotAHeading() {
        // e.g. a hex color or "#1" reference — not an ATX heading.
        let blocks = BossMessageMarkdown.blocks(from: "#1 priority")
        XCTAssertEqual(blocks, [.paragraph(text: "#1 priority")])
    }

    func testEmptyStringIsSingleBlank() {
        XCTAssertEqual(BossMessageMarkdown.blocks(from: ""), [.blank])
    }
}

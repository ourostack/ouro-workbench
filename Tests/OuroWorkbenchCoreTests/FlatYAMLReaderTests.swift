import XCTest
@testable import OuroWorkbenchCore

final class FlatYAMLReaderTests: XCTestCase {
    func testParsesSimpleKeyValuePairs() {
        let result = FlatYAMLReader.parse("id: abc\ncwd: /Users/me/project")
        XCTAssertEqual(result["id"], "abc")
        XCTAssertEqual(result["cwd"], "/Users/me/project")
    }

    func testStripsDoubleQuotedValues() {
        let result = FlatYAMLReader.parse(#"name: "My Session""#)
        XCTAssertEqual(result["name"], "My Session")
    }

    func testStripsSingleQuotedValues() {
        let result = FlatYAMLReader.parse("name: 'My Session'")
        XCTAssertEqual(result["name"], "My Session")
    }

    func testKeepsUnquotedValuesVerbatimAfterTrim() {
        let result = FlatYAMLReader.parse("repository:   owner_org/repo   ")
        XCTAssertEqual(result["repository"], "owner_org/repo")
    }

    func testSkipsCommentOnlyLines() {
        let result = FlatYAMLReader.parse("# a comment\nid: x\n   # indented comment")
        XCTAssertEqual(result, ["id": "x"])
    }

    func testSkipsBlankAndWhitespaceOnlyLines() {
        let result = FlatYAMLReader.parse("\n   \nid: x\n\t\n")
        XCTAssertEqual(result, ["id": "x"])
    }

    func testValueMayContainColons() {
        let result = FlatYAMLReader.parse("created_at: 2026-06-19T11:09:00Z")
        XCTAssertEqual(result["created_at"], "2026-06-19T11:09:00Z")
    }

    func testDuplicateKeyLastWins() {
        let result = FlatYAMLReader.parse("branch: old\nbranch: new")
        XCTAssertEqual(result["branch"], "new")
    }

    func testLineWithoutColonIsSkipped() {
        let result = FlatYAMLReader.parse("this has no colon\nid: x")
        XCTAssertEqual(result, ["id": "x"])
    }

    func testEmptyInputProducesEmptyDictionary() {
        XCTAssertEqual(FlatYAMLReader.parse(""), [:])
    }

    func testHandlesCRLFLineEndings() {
        let result = FlatYAMLReader.parse("id: x\r\ncwd: /tmp\r\n")
        XCTAssertEqual(result["id"], "x")
        XCTAssertEqual(result["cwd"], "/tmp")
    }

    func testEmptyValueIsEmptyString() {
        let result = FlatYAMLReader.parse("summary:")
        XCTAssertEqual(result["summary"], "")
    }

    func testKeyIsTrimmedOfSurroundingWhitespace() {
        let result = FlatYAMLReader.parse("   id   : x")
        XCTAssertEqual(result["id"], "x")
    }

    func testLineWithEmptyKeyIsSkipped() {
        let result = FlatYAMLReader.parse(": orphanValue\nid: x")
        XCTAssertEqual(result, ["id": "x"])
    }

    func testMismatchedQuoteIsNotStripped() {
        // A single leading quote with no matching trailing quote is left verbatim.
        let result = FlatYAMLReader.parse(#"name: "unterminated"#)
        XCTAssertEqual(result["name"], #""unterminated"#)
    }

    func testSingleCharacterQuoteIsNotTreatedAsAPair() {
        // A lone `"` is one character — not an open+close pair — so it stays.
        let result = FlatYAMLReader.parse(#"name: ""#)
        XCTAssertEqual(result["name"], #"""#)
    }
}

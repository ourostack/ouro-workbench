import XCTest
@testable import OuroWorkbenchCore

final class WorkbenchGroupColorTests: XCTestCase {
    func testFromTagParsesKnownColors() {
        XCTAssertEqual(WorkbenchGroupColor.from(tag: "blue"), .blue)
        XCTAssertEqual(WorkbenchGroupColor.from(tag: "teal"), .teal)
    }

    func testPaletteCasesExposeStableIdentifiersAndLabels() {
        XCTAssertEqual(WorkbenchGroupColor.gray.id, "gray")
        XCTAssertEqual(WorkbenchGroupColor.purple.label, "Purple")
        XCTAssertEqual(WorkbenchGroupColor.allCases.map(\.id), [
            "gray", "blue", "green", "orange", "red", "purple", "pink", "teal"
        ])
    }

    func testFromTagReturnsNilForNilOrUnknown() {
        XCTAssertNil(WorkbenchGroupColor.from(tag: nil))
        XCTAssertNil(WorkbenchGroupColor.from(tag: ""))
        // A color added in a newer build should degrade to untagged in an
        // older one rather than crash.
        XCTAssertNil(WorkbenchGroupColor.from(tag: "chartreuse"))
    }

    func testProjectColorTagSurvivesCodingRoundTrip() throws {
        let project = WorkbenchProject(name: "spoonjoy", rootPath: "/tmp/x", colorTag: "purple")
        let data = try JSONEncoder().encode(project)
        let decoded = try JSONDecoder().decode(WorkbenchProject.self, from: data)
        XCTAssertEqual(decoded.colorTag, "purple")
    }

    func testProjectDecodesWithoutColorTagForBackwardsCompatibility() throws {
        // Pre-colorTag persisted projects had no such key; decoding must
        // succeed with colorTag == nil rather than throwing.
        let olderJSON = """
        {
            "id": "00000000-0000-0000-0000-000000000001",
            "name": "older",
            "rootPath": "/tmp/older",
            "boss": { "agentName": "slugger", "scope": "machine" }
        }
        """.data(using: .utf8)!
        let decoded = try JSONDecoder().decode(WorkbenchProject.self, from: olderJSON)
        XCTAssertNil(decoded.colorTag)
        XCTAssertEqual(decoded.name, "older")
    }
}

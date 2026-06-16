import XCTest
@testable import OuroWorkbenchCore

final class WorkbenchContextFileTests: XCTestCase {
    func testDefaultURLUsesWorkbenchPathsRoot() throws {
        let root = try coverageBatch2TemporaryDirectory()
        let paths = WorkbenchPaths(rootURL: root)

        let url = WorkbenchContextFile.defaultURL(paths: paths)

        XCTAssertEqual(url, root.appendingPathComponent("agent-context.md"))
    }

    func testWriteCreatesParentAndRendersContext() throws {
        let root = try coverageBatch2TemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("nested/agent-context.md")

        let written = try WorkbenchContextFile.write(to: url, version: "1.2.3", boss: "slugger")

        XCTAssertEqual(written, url)
        let text = try String(contentsOf: url, encoding: .utf8)
        XCTAssertTrue(text.contains("1.2.3"))
        XCTAssertTrue(text.contains("slugger"))
    }
}

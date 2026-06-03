import XCTest
@testable import OuroWorkbenchCore

final class WorkbenchGuideTests: XCTestCase {
    func testShortcutCategoriesAreNonEmptyAndPopulated() {
        XCTAssertFalse(WorkbenchGuide.shortcutCategories.isEmpty)
        for category in WorkbenchGuide.shortcutCategories {
            XCTAssertFalse(category.title.isEmpty, "category \(category.id) has no title")
            XCTAssertFalse(category.systemImage.isEmpty, "category \(category.id) has no symbol")
            XCTAssertFalse(category.shortcuts.isEmpty, "category \(category.id) has no shortcuts")
        }
    }

    func testActionVerbsMatchTheCanonicalActionEnum() {
        // The single-source claim: the verbs advertised to the boss are exactly
        // the verbs the parser accepts, in declaration order.
        XCTAssertEqual(WorkbenchGuide.actionVerbs, BossWorkbenchActionKind.allCases.map(\.rawValue))
        XCTAssertTrue(WorkbenchGuide.actionVerbs.contains("sendInput"))
        XCTAssertTrue(WorkbenchGuide.actionVerbs.contains("recover"))
    }

    func testBossToolsCoverTheAdvertisedSurface() {
        let tools = Set(WorkbenchGuide.bossTools.map(\.tool))
        XCTAssertEqual(tools, [
            "workbench_status",
            "workbench_sessions",
            "workbench_sense",
            "workbench_transcript_tail",
            "workbench_search_transcripts",
            "workbench_recovery_drill",
            "workbench_request_action",
            "workbench_create_session"
        ])
    }

    func testSenseListsWorkbenchSessionsTool() {
        // `workbench_sense` is the boss's self-description of available tools; it
        // renders straight from `WorkbenchGuide.bossTools`. A boss relying on the
        // sense contract must learn the machine-readable session query exists.
        XCTAssertTrue(
            WorkbenchGuide.bossTools.contains { $0.tool == "workbench_sessions" },
            "bossTools should advertise workbench_sessions"
        )
        let sense = WorkbenchSenseRenderer().render(
            state: WorkspaceState(),
            summary: WorkspaceSummarizer().summarize(WorkspaceState())
        )
        XCTAssertTrue(sense.contains("workbench_sessions"), "sense output should list workbench_sessions")
    }

    func testShortcutsMarkdownRendersKnownBindings() {
        let markdown = WorkbenchGuide.shortcutsMarkdown()
        XCTAssertTrue(markdown.contains("Boss Check In"))
        XCTAssertTrue(markdown.contains("⌘K"))
        XCTAssertTrue(markdown.contains("Previous group"))
    }

    func testInnerAgentContextDescribesHostAndControls() {
        let context = WorkbenchGuide.innerAgentContext(version: "9.9.9", boss: "slugger")

        XCTAssertTrue(context.contains("running inside Ouro Workbench"))
        XCTAssertTrue(context.contains("9.9.9"))
        XCTAssertTrue(context.contains("slugger"))
        XCTAssertTrue(context.contains("OURO_WORKBENCH_CONTEXT_FILE"))
        XCTAssertTrue(context.contains("OURO_WORKBENCH_GROUP"))
        // Pulls the keyboard map and the capability list from the same catalog.
        XCTAssertTrue(context.contains("Boss Check In"))
        XCTAssertTrue(context.contains("workbench_request_action"))
    }

    func testInnerAgentContextWithoutBossStaysGeneric() {
        let context = WorkbenchGuide.innerAgentContext(version: "1.0.0", boss: nil)
        XCTAssertTrue(context.contains("A selected Ouro boss agent watches"))
    }

    func testContextFileWritesRenderedDocument() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("workbench-guide-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("agent-context.md")

        let written = try WorkbenchContextFile.write(to: url, version: "2.3.4", boss: "slugger")
        XCTAssertEqual(written, url)

        let contents = try String(contentsOf: url, encoding: .utf8)
        XCTAssertTrue(contents.contains("running inside Ouro Workbench"))
        XCTAssertTrue(contents.contains("2.3.4"))
        XCTAssertTrue(contents.contains("slugger"))
    }
}

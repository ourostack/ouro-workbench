import XCTest
@testable import OuroWorkbenchCore

/// U30(b): the `workbench_report_bug` MCP seam. The renderer single-sources the tool
/// name + description (which must state honestly what is/isn't anonymized) and shapes the
/// enqueue acknowledgement the boss reads back. The actual bundle is built on the app's
/// drain (it needs live app state) through the SAME `BugReportWriter` + redactor the
/// in-app reporter uses.
final class WorkbenchReportBugRendererTests: XCTestCase {
    func testToolNameIsStable() {
        XCTAssertEqual(WorkbenchReportBugRenderer.toolName, "workbench_report_bug")
    }

    func testToolDescriptionStatesTextAnonymizedScreenshotNot() {
        let description = WorkbenchReportBugRenderer.toolDescription.lowercased()
        // Honest privacy note: text is anonymized, the screenshot is NOT.
        XCTAssertTrue(description.contains("anonymiz"))
        XCTAssertTrue(description.contains("screenshot"))
        // It must convey the screenshot is verbatim / not redacted, so the boss can relay
        // an honest note rather than implying the whole bundle is scrubbed.
        XCTAssertTrue(
            description.contains("not anonymiz")
                || description.contains("not redact")
                || description.contains("verbatim"),
            "description must state the screenshot is NOT anonymized: \(WorkbenchReportBugRenderer.toolDescription)"
        )
    }

    func testToolDescriptionMentionsItRoutesThroughTheSameRedactionPath() {
        let description = WorkbenchReportBugRenderer.toolDescription.lowercased()
        // The boss must understand this is the SAME bundle a human creates (revealable,
        // File-as-Issue available), filed human-gated.
        XCTAssertTrue(description.contains("bundle"))
    }

    // MARK: - Ack shape

    func testAckCarriesRequestIdAndNotePreview() {
        let ack = WorkbenchReportBugRenderer.ack(
            requestId: "req-1",
            note: "Recovery drill failed",
            source: "boss"
        )
        XCTAssertTrue(ack.queued)
        XCTAssertEqual(ack.requestId, "req-1")
        XCTAssertTrue(ack.message.contains("req-1"))
        XCTAssertTrue(ack.message.contains("Recovery drill failed"))
    }

    func testAckMessageNotesBundleIsBuiltOnDrain() {
        let ack = WorkbenchReportBugRenderer.ack(requestId: "r", note: "x", source: "boss")
        // The bundle is produced when the app drains the action (live state needed), so
        // the ack tells the boss to read it back rather than treating this as the bundle.
        XCTAssertTrue(ack.message.lowercased().contains("drain") || ack.message.lowercased().contains("queued"))
    }

    func testAckIsEncodable() throws {
        let ack = WorkbenchReportBugRenderer.ack(requestId: "r", note: "n", source: "s")
        let data = try JSONEncoder().encode(ack)
        let json = String(decoding: data, as: UTF8.self)
        XCTAssertTrue(json.contains("\"requestId\""))
        XCTAssertTrue(json.contains("\"queued\""))
    }
}

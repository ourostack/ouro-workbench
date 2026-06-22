import XCTest
@testable import OuroWorkbenchCore

/// F12a Gap 1 — durable wiring assertions for the `save()`-fail honesty fix.
///
/// The pure `WorkbenchActionResultClassifier` (with the new `isApplied` precedence
/// and the `.appliedUnconfirmed` state) is unit-tested + 100% covered in Core. The
/// MCP server that wires it (`Sources/OuroWorkbenchMCP/`) is not coverage-gated and
/// can't be imported by the Core test target, so we source-pin its structural
/// wiring the same `mcpSource()` way `MCPDegradedReadWiringTests` /
/// `MCPDedupWiringTests` do.
///
/// The risk these pins defend (the spec's behavioral risk for gap 1):
///   - the `isApplied` signal MUST be read from the durable F11b ledger
///     (`queue.appliedRequestIds()`) in the MCP wiring — not hardcoded — so the
///     classifier can resolve `.appliedUnconfirmed` only when the action actually
///     ran but its log entry was lost to a save() throw;
///   - that ledger read must be threaded into `readback(...)` so the precedence
///     (queued → log → applied → unknown) is the tested Core decision, not an
///     ad-hoc App branch;
///   - the tool description must document the new `appliedUnconfirmed` state so the
///     boss knows it means "ran, outcome text lost" (succeeded:true), not a lie.
final class MCPActionResultWiringTests: XCTestCase {
    func testActionResultReadsTheAppliedLedgerAndThreadsItIntoReadback() throws {
        let body = try actionResultBody()
        // The ledger read: the durable F11b applied-id set, consulted by id.
        XCTAssertTrue(
            body.contains("queue.appliedRequestIds()"),
            "actionResult must read the durable applied-id ledger (queue.appliedRequestIds()) — the isApplied signal must NOT be hardcoded"
        )
        XCTAssertTrue(
            body.contains("appliedRequestIds().contains("),
            "actionResult must test ledger membership for THIS requestId's uuid"
        )
        // It must be passed into the classifier (the tested precedence lives in Core).
        let ledgerIndex = try XCTUnwrap(
            body.range(of: "appliedRequestIds()")?.lowerBound,
            "actionResult must read the applied ledger"
        )
        let readbackIndex = try XCTUnwrap(
            body.range(of: "actionResultClassifier.readback(")?.lowerBound,
            "actionResult must classify via the Core readback seam"
        )
        XCTAssertLessThan(
            ledgerIndex, readbackIndex,
            "the applied-ledger read must happen BEFORE it's threaded into readback(...)"
        )
        XCTAssertTrue(
            body.contains("isApplied:"),
            "the readback call must thread the isApplied argument (the new gap-1 precedence input)"
        )
    }

    func testMalformedIdNeverReadsAsApplied() throws {
        let body = try actionResultBody()
        // A non-UUID requestId can't be in the queue OR the ledger (both keyed by
        // UUID). The existing stillQueued=false default for the malformed branch
        // must carry an isApplied=false too, so a malformed id resolves to
        // .unknown via the log lookup — never a spurious .appliedUnconfirmed.
        XCTAssertTrue(
            body.contains("if let uuid = UUID(uuidString: requestId)"),
            "actionResult must gate the queue/ledger reads on a valid UUID"
        )
        XCTAssertTrue(
            body.contains("isApplied = false"),
            "the malformed-id branch must default isApplied to false (a non-UUID id is never in the ledger)"
        )
    }

    func testToolDescriptionDocumentsAppliedUnconfirmed() throws {
        let source = try mcpSource()
        let descIndex = try XCTUnwrap(
            source.range(of: "\"name\": \"workbench_action_result\"")?.upperBound,
            "the workbench_action_result tool must be declared"
        )
        let descTail = String(source[descIndex...].prefix(2000))
        XCTAssertTrue(
            descTail.contains("appliedUnconfirmed"),
            "the tool description must document the appliedUnconfirmed state (ran; outcome text lost to a save failure)"
        )
        XCTAssertTrue(
            descTail.contains("state save failed") || descTail.contains("save failed"),
            "the description must explain appliedUnconfirmed means the action ran but its outcome wasn't persisted (a save failure), succeeded but unconfirmed"
        )
    }

    // MARK: - Helpers (mcpSource idiom, mirroring MCPDegradedReadWiringTests)

    private func actionResultBody() throws -> String {
        let source = try mcpSource()
        return try sourceSlice(
            in: source,
            from: "private func actionResult(arguments: [String: Any]) throws -> String {",
            to: "\n    /// The inline waiting-prompt snippet"
        )
    }

    private func mcpSource() throws -> String {
        let url = repoRoot()
            .appendingPathComponent("Sources")
            .appendingPathComponent("OuroWorkbenchMCP")
            .appendingPathComponent("OuroWorkbenchMCPMain.swift")
        return try String(contentsOf: url, encoding: .utf8)
    }

    private func repoRoot() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    private func sourceSlice(in source: String, from startMarker: String, to endMarker: String) throws -> String {
        let start = try XCTUnwrap(source.range(of: startMarker)?.lowerBound, "missing start marker: \(startMarker)")
        let end = try XCTUnwrap(source.range(of: endMarker, range: start..<source.endIndex)?.lowerBound, "missing end marker: \(endMarker)")
        return String(source[start..<end])
    }
}

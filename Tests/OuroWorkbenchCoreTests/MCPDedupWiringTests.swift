import XCTest
@testable import OuroWorkbenchCore

/// F10a wiring pin. `Sources/OuroWorkbenchMCP/` (the MCP server binary) is not
/// coverage-gated and can't be exercised through the synchronous readLine loop
/// in CI, so we pin its structural wiring by reading the source directly — the
/// same technique BossForwardStatusWiringTests uses for the App target.
///
/// These assertions defend the behavioral risks a source grep can't see by
/// pinning the ORDER and SHAPE of the dedup chokepoint:
///  - the notification short-circuit precedes the ledger (notifications never
///    enter dedup);
///  - `observe` precedes the dispatch switch / `callTool` (the side-effecting
///    handlers run strictly AFTER `.proceed`);
///  - `complete` is reached on BOTH the success arm and the catch arm (one
///    exit), so a thrown handler releases its in-flight slot;
///  - `.replayCached` returns the cached payload WITHOUT re-entering `callTool`;
///  - `.rejectInFlight` and the parse / method-not-found / serialization error
///    sites route through `MCPError`'s mapping rather than inline literals.
final class MCPDedupWiringTests: XCTestCase {
    // MARK: - The ledger is declared on the server

    func testServerDeclaresDedupLedger() throws {
        let source = try mcpSource()
        XCTAssertTrue(
            source.contains("dedupLedger") && source.contains("MCPRequestDedupLedger"),
            "WorkbenchMCPServer must hold an MCPRequestDedupLedger field"
        )
    }

    // MARK: - Ordering inside handle(line:)

    func testNotificationGuardPrecedesLedgerObserve() throws {
        let handle = try handleBody()
        let notifGuard = try XCTUnwrap(
            handle.range(of: #"hasPrefix("notifications/")"#)?.lowerBound,
            "notification short-circuit must exist in handle(line:)"
        )
        let observe = try XCTUnwrap(
            handle.range(of: "dedupLedger.observe")?.lowerBound,
            "handle(line:) must call dedupLedger.observe"
        )
        XCTAssertTrue(
            notifGuard < observe,
            "the notification short-circuit must precede observe so notifications never enter dedup"
        )
    }

    func testObservePrecedesCallTool() throws {
        let handle = try handleBody()
        let observe = try XCTUnwrap(handle.range(of: "dedupLedger.observe")?.lowerBound)
        let callTool = try XCTUnwrap(
            handle.range(of: "callTool(")?.lowerBound,
            "handle(line:) must dispatch through callTool"
        )
        XCTAssertTrue(
            observe < callTool,
            "observe must precede callTool so every side-effecting handler runs only after .proceed"
        )
    }

    func testKeyDerivedViaMCPRequestKeyFrom() throws {
        let handle = try handleBody()
        XCTAssertTrue(
            handle.contains("MCPRequestKey.from(rawID:"),
            "the dedup key must be derived from the raw id via MCPRequestKey.from"
        )
    }

    func testDateInjectedOnlyAtTheCallBoundary() throws {
        let handle = try handleBody()
        // Date() appears at the wiring boundary feeding observe/complete — the
        // pure ledger itself never calls Date(). We pin that observe is fed a
        // now from Date() here at the call site.
        XCTAssertTrue(handle.contains("Date()"), "now must be Date() at the call boundary")
    }

    // MARK: - The three decision arms

    func testReplayCachedReturnsWithoutReenteringCallTool() throws {
        let handle = try handleBody()
        let arm = try sourceSlice(in: handle, from: "case .replayCached", to: "case .rejectInFlight")
        XCTAssertFalse(
            arm.contains("callTool("),
            ".replayCached must return the cached payload verbatim, never re-enter callTool"
        )
    }

    func testRejectInFlightRoutesThroughMCPError() throws {
        let handle = try handleBody()
        let arm = try sourceSlice(in: handle, from: "case .rejectInFlight", to: "case .proceed")
        XCTAssertTrue(
            arm.contains("MCPError.duplicateInFlight"),
            ".rejectInFlight must build its error from MCPError.duplicateInFlight.jsonRPCError"
        )
    }

    // MARK: - One exit: complete fires on both the success and the catch arm

    func testCompleteReachableFromBothArms() throws {
        let handle = try handleBody()
        // One-exit shape: a single `complete(...)` call sits after the do/catch
        // computes `response` on EITHER arm, then returns. So `complete` must
        // appear exactly once for the .proceed path, AFTER the catch block.
        let catchRange = try XCTUnwrap(
            handle.range(of: "} catch {"),
            "handle(line:) must have a catch arm"
        )
        let completeAfterCatch = handle.range(
            of: "dedupLedger.complete",
            range: catchRange.upperBound..<handle.endIndex
        )
        XCTAssertNotNil(
            completeAfterCatch,
            "complete must fire after the do/catch (one exit) so it runs for BOTH the success and the thrown arm"
        )
    }

    func testProceedPathDoesNotCompleteInsideEitherArmSeparately() throws {
        let handle = try handleBody()
        // Guard against the leak bug: complete() must NOT live inside the do
        // block (success-only) where a thrown handler would skip it. There is
        // exactly one complete() call, and it is after the catch.
        let occurrences = handle.components(separatedBy: "dedupLedger.complete").count - 1
        XCTAssertEqual(
            occurrences, 1,
            "there must be exactly one complete() call (the one-exit point), not a per-arm duplicate"
        )
    }

    // MARK: - The legacy error sites route through MCPError mapping

    func testParseErrorRoutesThroughMCPError() throws {
        let handle = try handleBody()
        XCTAssertTrue(
            handle.contains("MCPError.parseError"),
            "the parse-error site must build its code/message from MCPError.parseError"
        )
    }

    func testMethodNotFoundRoutesThroughMCPError() throws {
        let handle = try handleBody()
        XCTAssertTrue(
            handle.contains("MCPError.methodNotFound"),
            "the unknown-method site must build its code/message from MCPError.methodNotFound"
        )
    }

    func testSerializationFallbackRoutesThroughMCPError() throws {
        let source = try mcpSource()
        let write = try sourceSlice(in: source, from: "private func write(", to: "struct MCPToolFailure")
        XCTAssertTrue(
            write.contains("MCPError.internalError"),
            "the write() serialization fallback must build its error from MCPError.internalError"
        )
    }

    // MARK: - Belt-and-suspenders: the action-fingerprint dedup STAYS

    func testActionFingerprintDedupRemains() throws {
        let queueSource = try coreSource("WorkbenchActionRequestQueue.swift")
        XCTAssertTrue(
            queueSource.contains("fingerprint"),
            "the disjoint action-fingerprint dedup must remain — F10a does not replace it"
        )
    }

    // MARK: - Helpers

    private func handleBody() throws -> String {
        let source = try mcpSource()
        return try sourceSlice(in: source, from: "private func handle(line:", to: "private func callTool(")
    }

    private func mcpSource() throws -> String {
        let url = repoRoot()
            .appendingPathComponent("Sources")
            .appendingPathComponent("OuroWorkbenchMCP")
            .appendingPathComponent("OuroWorkbenchMCPMain.swift")
        return try String(contentsOf: url, encoding: .utf8)
    }

    private func coreSource(_ filename: String) throws -> String {
        let url = repoRoot()
            .appendingPathComponent("Sources")
            .appendingPathComponent("OuroWorkbenchCore")
            .appendingPathComponent(filename)
        return try String(contentsOf: url, encoding: .utf8)
    }

    private func repoRoot() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    private func sourceSlice(in source: String, from startMarker: String, to endMarker: String) throws -> String {
        let start = try XCTUnwrap(source.range(of: startMarker)?.lowerBound)
        let end = try XCTUnwrap(source.range(of: endMarker, range: start..<source.endIndex)?.lowerBound)
        return String(source[start..<end])
    }
}

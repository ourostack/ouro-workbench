import XCTest
@testable import OuroWorkbenchCore

/// F10b wiring + conformance pins. Two of these can't be exercised through the
/// synchronous readLine loop in CI (the `Sources/OuroWorkbenchMCP/` binary is
/// not coverage-gated and can't be imported by the Core test target), so we pin
/// the structural wiring by reading the source directly — the same `mcpSource()`
/// technique MCPDedupWiringTests uses for the dedup chokepoint.
///
/// What these defend (the spec's behavioral risks a runtime test can't see):
///  - the LocalizedError conformance line itself — `localizedDescription` only
///    returns `errorDescription` when the error conforms, so the dispatch catch
///    only surfaces the honest message because of it;
///  - `workbenchStatus()` consults `degradedReadReason(for:)` + `.advisory`, and
///    the schema arm `return`s the advisory BEFORE the fall-through `throw`
///    (ordering — so a newer-schema state renders as content, not an error);
///  - the dispatch catch is still the single funnel that routes
///    `error.localizedDescription` into `toolResult(isError:true)` — a future
///    per-handler refactor that breaks this would silently un-cover Seam A.
final class MCPDegradedReadWiringTests: XCTestCase {
    // MARK: - Seam A: the conformance line is the load-bearing safety net

    func testWorkbenchStoreErrorConformsToLocalizedError() throws {
        let source = try coreSource("WorkbenchStore.swift")
        XCTAssertTrue(
            source.contains("WorkbenchStoreError: Error, LocalizedError, Equatable")
                || source.contains("WorkbenchStoreError: LocalizedError")
                || source.range(of: #"WorkbenchStoreError:[^\{]*LocalizedError"#, options: .regularExpression) != nil,
            "WorkbenchStoreError must conform to LocalizedError — without it localizedDescription returns the Foundation default and the boss is blinded"
        )
        // The conformance is only honest if it actually provides errorDescription.
        XCTAssertTrue(
            source.contains("public var errorDescription: String?"),
            "the LocalizedError conformance must implement errorDescription"
        )
    }

    // MARK: - Option B: workbench_status renders the schema advisory as content

    func testWorkbenchStatusConsultsDegradedReadReasonAndAdvisory() throws {
        let body = try statusBody()
        XCTAssertTrue(
            body.contains("degradedReadReason(for:"),
            "workbenchStatus() must consult degradedReadReason(for:) so a newer-schema state becomes content, not an error"
        )
        XCTAssertTrue(
            body.contains(".advisory"),
            "workbenchStatus() must return the reason's .advisory line as content"
        )
    }

    func testWorkbenchStatusOnlyReturnsContentForTheSchemaCase() throws {
        let body = try statusBody()
        XCTAssertTrue(
            body.contains("case .stateWrittenByNewerWorkbench"),
            "Option B must gate the content-not-error path on the schema case only — genuine corruption (.stateUnreadable) must still surface honestly via Seam A"
        )
    }

    func testSchemaAdvisoryReturnsBeforeTheFallThroughThrow() throws {
        let body = try statusBody()
        // Ordering: inside the catch, the schema arm must `return r.advisory`
        // BEFORE the unconditional `throw` that re-raises everything else. If the
        // throw came first, the advisory branch would be dead and a newer-schema
        // state would surface as an error instead of content.
        let advisoryReturn = try XCTUnwrap(
            body.range(of: "return")?.lowerBound,
            "the schema arm must return the advisory"
        )
        let fallThroughThrow = try XCTUnwrap(
            body.range(of: "throw error")?.lowerBound,
            "the catch must re-throw non-schema errors so Seam A surfaces them"
        )
        XCTAssertTrue(
            advisoryReturn < fallThroughThrow,
            "the schema arm's `return advisory` must precede the fall-through `throw error`"
        )
    }

    // MARK: - The dispatch catch is still the single funnel (Seam A's reach)

    func testDispatchCatchRoutesLocalizedDescriptionToIsErrorResult() throws {
        let handle = try handleBody()
        // The single catch that turns ANY thrown read error into an isError:true
        // tools/call result by reading error.localizedDescription. Seam A's honest
        // message reaches all ~15 read tools ONLY because this funnel exists; a
        // per-handler refactor that bypasses it would silently un-cover Seam A.
        let catchRange = try XCTUnwrap(
            handle.range(of: "} catch {"),
            "handle(line:) must have a catch arm"
        )
        let tail = String(handle[catchRange.upperBound...])
        XCTAssertTrue(
            tail.contains("error.localizedDescription"),
            "the dispatch catch must read error.localizedDescription (the property Seam A's errorDescription backs)"
        )
        XCTAssertTrue(
            tail.contains("isError: true"),
            "the dispatch catch must route the message into a toolResult(isError: true)"
        )
    }

    // MARK: - Helpers (mcpSource idiom, mirroring MCPDedupWiringTests)

    private func statusBody() throws -> String {
        let source = try mcpSource()
        return try sourceSlice(in: source, from: "private func workbenchStatus(", to: "private func onboardingStatus(")
    }

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

import XCTest
@testable import OuroWorkbenchCore

/// Seam A (#F9): the pure `tools/list` → present|absent injection verdict, and the
/// tolerant JSON-RPC parse that feeds it. These are framework-free and exhaustively
/// covered with string/array fixtures — no live `ouro mcp-serve` process.
final class WorkbenchToolsInjectionProbeTests: XCTestCase {

    // MARK: verdict(fromToolNames:)

    func testPresentWhenAnyAdvertisedWorkbenchToolAppears() {
        let names = ["workbench_status", "ask", "status"]
        XCTAssertEqual(WorkbenchToolsInjectionProbe.verdict(fromToolNames: names), .present)
    }

    func testPresentWhenEveryAdvertisedToolAppears() {
        let names = Array(WorkbenchGuide.advertisedToolNames)
        XCTAssertEqual(WorkbenchToolsInjectionProbe.verdict(fromToolNames: names), .present)
    }

    /// The silent-strip case: an old `ouro mcp-serve` that ignored `--workbench-mcp`
    /// answers `tools/list` with ONLY the boss's native ouro tools. Must be `.absent`.
    func testAbsentForBossNativeOnlyToolList() {
        let names = ["ask", "status", "catchup"]
        XCTAssertEqual(WorkbenchToolsInjectionProbe.verdict(fromToolNames: names), .absent)
    }

    func testAbsentForEmptyToolNames() {
        XCTAssertEqual(WorkbenchToolsInjectionProbe.verdict(fromToolNames: []), .absent)
    }

    func testAbsentForCaseMismatchedName() {
        // Recognition is exact-match against the canonical set, not a case-folded prefix.
        XCTAssertEqual(WorkbenchToolsInjectionProbe.verdict(fromToolNames: ["Workbench_Status"]), .absent)
    }

    func testPresentWhenOneValidAmongManyInvalid() {
        let names = ["ask", "status", "catchup", "delegate", "workbench_sessions", "report_blocker"]
        XCTAssertEqual(WorkbenchToolsInjectionProbe.verdict(fromToolNames: names), .present)
    }

    /// The verdict recognizes via `WorkbenchGuide.advertisedToolNames` (reused as the
    /// single source) — NOT a hand-rolled `hasPrefix("workbench_")`. Pin that contract.
    func testRecognitionIsKeyedOnTheAdvertisedSet() {
        for name in WorkbenchGuide.advertisedToolNames {
            XCTAssertEqual(
                WorkbenchToolsInjectionProbe.verdict(fromToolNames: [name]),
                .present,
                "advertised tool \(name) should be recognized as present"
            )
        }
    }

    // MARK: toolNames(fromToolsListJSON:)

    func testParsesToolNamesFromWellFormedToolsList() {
        let line = #"{"jsonrpc":"2.0","id":2,"result":{"tools":[{"name":"workbench_status"},{"name":"ask"}]}}"#
        XCTAssertEqual(
            WorkbenchToolsInjectionProbe.toolNames(fromToolsListJSON: line),
            ["workbench_status", "ask"]
        )
    }

    func testParsesEmptyToolsArray() {
        let line = #"{"jsonrpc":"2.0","id":2,"result":{"tools":[]}}"#
        XCTAssertEqual(WorkbenchToolsInjectionProbe.toolNames(fromToolsListJSON: line), [])
    }

    func testResultWithoutToolsKeyYieldsEmpty() {
        let line = #"{"jsonrpc":"2.0","id":2,"result":{}}"#
        XCTAssertEqual(WorkbenchToolsInjectionProbe.toolNames(fromToolsListJSON: line), [])
    }

    func testRPCErrorResponseYieldsEmpty() {
        // An old runtime that errors on tools/list (no result) ⇒ [] ⇒ .absent (not ready).
        let line = #"{"jsonrpc":"2.0","id":2,"error":{"code":-32601,"message":"x"}}"#
        XCTAssertEqual(WorkbenchToolsInjectionProbe.toolNames(fromToolsListJSON: line), [])
    }

    func testNonJSONLineYieldsEmpty() {
        XCTAssertEqual(WorkbenchToolsInjectionProbe.toolNames(fromToolsListJSON: "not json"), [])
    }

    func testTopLevelNonObjectJSONYieldsEmpty() {
        // Valid JSON, but an array at top level — exercises the not-an-object guard.
        XCTAssertEqual(WorkbenchToolsInjectionProbe.toolNames(fromToolsListJSON: "[1,2,3]"), [])
    }

    func testToolsNotAnArrayYieldsEmpty() {
        // `tools` present but not an array — exercises the non-array guard.
        let line = #"{"result":{"tools":"oops"}}"#
        XCTAssertEqual(WorkbenchToolsInjectionProbe.toolNames(fromToolsListJSON: line), [])
    }

    func testNamelessToolEntriesAreSkipped() {
        let line = #"{"result":{"tools":[{"name":"workbench_status"},{"description":"no name"},{"name":"ask"}]}}"#
        XCTAssertEqual(
            WorkbenchToolsInjectionProbe.toolNames(fromToolsListJSON: line),
            ["workbench_status", "ask"]
        )
    }

    func testNonObjectToolEntriesAreSkipped() {
        // A tools array containing a non-object element — the entry-cast guard.
        let line = #"{"result":{"tools":[{"name":"workbench_status"},"junk",{"name":"ask"}]}}"#
        XCTAssertEqual(
            WorkbenchToolsInjectionProbe.toolNames(fromToolsListJSON: line),
            ["workbench_status", "ask"]
        )
    }

    func testEmptyLineYieldsEmpty() {
        XCTAssertEqual(WorkbenchToolsInjectionProbe.toolNames(fromToolsListJSON: ""), [])
    }

    // MARK: end-to-end (parse → verdict)

    func testSilentStripJSONParsesToAbsentVerdict() {
        let line = #"{"jsonrpc":"2.0","id":2,"result":{"tools":[{"name":"ask"},{"name":"status"}]}}"#
        let names = WorkbenchToolsInjectionProbe.toolNames(fromToolsListJSON: line)
        XCTAssertEqual(WorkbenchToolsInjectionProbe.verdict(fromToolNames: names), .absent)
    }

    func testInjectedJSONParsesToPresentVerdict() {
        let line = #"{"jsonrpc":"2.0","id":2,"result":{"tools":[{"name":"ask"},{"name":"workbench_sessions"}]}}"#
        let names = WorkbenchToolsInjectionProbe.toolNames(fromToolsListJSON: line)
        XCTAssertEqual(WorkbenchToolsInjectionProbe.verdict(fromToolNames: names), .present)
    }
}

import XCTest
@testable import OuroWorkbenchCore

/// F10a Core seam 2: the JSON-RPC protocol error vocabulary. Every case must
/// carry a non-opaque `errorDescription` (LocalizedError) that names the salient
/// detail, and a `jsonRPCError` mapping to the canonical code — except
/// `.toolFailure`, which by MCP convention surfaces as an `isError:true`
/// tools/call result, NOT a protocol-level error (so its `jsonRPCError` is nil).
final class MCPErrorTests: XCTestCase {
    // MARK: - errorDescription is never opaque, names the salient detail

    func testParseErrorDescriptionNamesDetail() {
        let error = MCPError.parseError(detail: "expected one object per line")
        let description = try? XCTUnwrap(error.errorDescription)
        XCTAssertNotNil(description)
        XCTAssertFalse(error.errorDescription!.isEmpty)
        XCTAssertTrue(error.errorDescription!.contains("expected one object per line"))
    }

    func testMethodNotFoundDescriptionNamesMethod() {
        let error = MCPError.methodNotFound(method: "frobnicate")
        XCTAssertFalse(error.errorDescription!.isEmpty)
        XCTAssertTrue(error.errorDescription!.contains("frobnicate"))
    }

    func testInvalidParamsDescriptionNamesDetail() {
        let error = MCPError.invalidParams(detail: "missing tool name")
        XCTAssertFalse(error.errorDescription!.isEmpty)
        XCTAssertTrue(error.errorDescription!.contains("missing tool name"))
    }

    func testDuplicateInFlightDescriptionNamesId() {
        let error = MCPError.duplicateInFlight(id: "req-42")
        XCTAssertFalse(error.errorDescription!.isEmpty)
        XCTAssertTrue(error.errorDescription!.contains("req-42"))
    }

    func testToolFailureDescriptionNamesMessage() {
        let error = MCPError.toolFailure(message: "store unavailable")
        XCTAssertFalse(error.errorDescription!.isEmpty)
        XCTAssertTrue(error.errorDescription!.contains("store unavailable"))
    }

    func testInternalErrorDescriptionNamesDetail() {
        let error = MCPError.internalError(detail: "response could not be serialized")
        XCTAssertFalse(error.errorDescription!.isEmpty)
        XCTAssertTrue(error.errorDescription!.contains("response could not be serialized"))
    }

    // MARK: - jsonRPCError canonical codes

    func testParseErrorJSONRPCCode() {
        let mapping = try? XCTUnwrap(MCPError.parseError(detail: "x").jsonRPCError)
        XCTAssertEqual(mapping?.code, -32700)
        XCTAssertFalse(mapping!.message.isEmpty)
        XCTAssertTrue(mapping!.message.contains("x"))
    }

    func testMethodNotFoundJSONRPCCode() {
        let mapping = try? XCTUnwrap(MCPError.methodNotFound(method: "frob").jsonRPCError)
        XCTAssertEqual(mapping?.code, -32601)
        XCTAssertTrue(mapping!.message.contains("frob"))
    }

    func testInvalidParamsJSONRPCCode() {
        let mapping = try? XCTUnwrap(MCPError.invalidParams(detail: "bad").jsonRPCError)
        XCTAssertEqual(mapping?.code, -32602)
        XCTAssertTrue(mapping!.message.contains("bad"))
    }

    func testDuplicateInFlightJSONRPCCode() {
        let mapping = try? XCTUnwrap(MCPError.duplicateInFlight(id: "req-7").jsonRPCError)
        // duplicate-in-flight maps onto the JSON-RPC internal error band; a
        // retried-while-running request is a server-side condition the caller
        // can't fix by reformatting, but it is reported as a protocol error.
        XCTAssertEqual(mapping?.code, -32603)
        XCTAssertTrue(mapping!.message.contains("req-7"))
    }

    func testInternalErrorJSONRPCCode() {
        let mapping = try? XCTUnwrap(MCPError.internalError(detail: "boom").jsonRPCError)
        XCTAssertEqual(mapping?.code, -32603)
        XCTAssertTrue(mapping!.message.contains("boom"))
    }

    func testToolFailureHasNoJSONRPCError() {
        // The MCP convention: a tool's own failure is a tools/call result with
        // isError:true (so the model sees it), NOT a protocol-level JSON-RPC
        // error. Hence nil — and the wiring must route it to toolResult.
        XCTAssertNil(MCPError.toolFailure(message: "anything").jsonRPCError)
    }

    // MARK: - Equatable / Sendable conformance is usable

    func testEquatableDistinguishesCases() {
        XCTAssertEqual(MCPError.parseError(detail: "a"), MCPError.parseError(detail: "a"))
        XCTAssertNotEqual(MCPError.parseError(detail: "a"), MCPError.parseError(detail: "b"))
        XCTAssertNotEqual(MCPError.parseError(detail: "a"), MCPError.invalidParams(detail: "a"))
    }
}
